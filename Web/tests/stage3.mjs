import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import net from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright-core';

// Stage 3 only. Account bootstrap/login are fixture setup, not earlier-stage suites.
const cwd = fileURLToPath(new URL('../..', import.meta.url));
const home = await mkdtemp(join(tmpdir(),'tefter-stage3-browser-'));
const source = await mkdtemp(join(tmpdir(),'tefter-stage3-source-'));
const probe = net.createServer().listen(0,'127.0.0.1');
await once(probe,'listening'); const port = probe.address().port;
await new Promise(resolve=>probe.close(resolve));
const env = {...process.env,TEFTER_HOME:home,TEFTER_PORT:String(port)};
const url = 'http://127.0.0.1:'+port;
const binary = process.env.TEFTER_TEST_BINARY || '.build/debug/tefter';
const email='stage3@example.test', password='stage three browser password';
let server, browser;
try {
  for (const args of [['init','--initial-branch=main'],['config','user.name','Stage3'],['config','user.email',email]])
    assert.equal(spawnSync('/usr/bin/git',args,{cwd:source}).status,0);
  await writeFile(join(source,'note.md'),'Initial repository');
  assert.equal(spawnSync('/usr/bin/git',['add','.'],{cwd:source}).status,0);
  assert.equal(spawnSync('/usr/bin/git',['commit','-m','Initial'],{cwd:source}).status,0);
  const bootstrap=spawnSync(binary,['bootstrap',email],{cwd,env,input:password+'\n'});
  assert.equal(bootstrap.status,0,bootstrap.stderr.toString());
  server=spawn(binary,[],{cwd,env,stdio:'ignore'});
  for(let n=0;n<100;n++){
    if(await fetch(url+'/api/v1/ready').then(r=>r.ok,()=>false))break;
    await new Promise(r=>setTimeout(r,50));
  }
  browser=await chromium.launch({channel:'chrome',headless:true,executablePath:process.env.TEFTER_TEST_CHROME || undefined});
  const page=await browser.newPage(); const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.goto(url);
  await page.getByLabel('Email',{exact:true}).first().fill(email);
  await page.getByLabel('Password',{exact:true}).fill(password);
  await page.getByRole('button',{name:'Sign in',exact:true}).click();
  const release = await (await fetch(url+'/api/v1/version')).json();
  await page.getByText('Account and administration', {exact:true}).click();
  await page.getByText(`Tefter ${release.version} (${release.build.slice(0,7)})`, {exact:true}).waitFor();
  await page.getByRole('button',{name:'Repos',exact:true}).click();
  await page.getByText('No repositories registered or granted to this space.').waitFor();
  await page.getByLabel('Name',{exact:true}).fill('Browser repository');
  await page.getByLabel('Credential-free URL or absolute local path').fill(source);
  await page.getByLabel('Description',{exact:true}).fill('Stage 3 browser validation');
  await page.getByRole('button',{name:'Register Repo',exact:true}).click();
  await page.getByRole('heading',{name:'Browser repository'}).waitFor();
  await page.getByRole('button',{name:'Status and commits'}).click();
  await page.getByText('No checkout available.',{exact:true}).waitFor();
  await page.getByRole('button',{name:'Create separate checkout (installation admin)'}).click();
  await page.getByText('Branch: main', {exact:false}).waitFor();
  await page.getByRole('button',{name:'Comments',exact:true}).click();
  await page.getByLabel('New comment',{exact:true}).fill('Durable Repo review note');
  await page.getByRole('button',{name:'Save comment',exact:true}).click();
  await page.getByText('Durable Repo review note',{exact:true}).waitFor();
  await page.getByRole('button',{name:'Sessions',exact:true}).click();
  await page.getByText('No execution connection authorized',{exact:false}).waitFor();
  assert.equal(await page.getByRole('button',{name:'Start session',exact:true}).isDisabled(),true);
  const structured = join(home, 'structured-fixture');
  const interactive = join(home, 'interactive-fixture');
  await writeFile(structured, `#!/bin/sh
cat >/dev/null
echo '{"type":"item.completed","item":{"type":"agent_message","text":"Ready"}}'
`, {mode: 0o700});
  await writeFile(interactive, `#!/bin/sh
test -t 0 && test -t 1 || exit 1
echo $$ > "$HOME/terminal.pid"
stty -echo
echo READY
while IFS= read -r line; do echo "Received $line"; stty size; done
`, {mode: 0o700});
  const fixture = await page.evaluate(async ({home, structured, interactive}) => {
    const base = '/api/v1/';
    const {user, csrf} = await (await fetch(base+'session')).json();
    const {spaces} = await (await fetch(base+'spaces')).json();
    const space = spaces[0].id;
    async function change(path, method, data) {
      const response = await fetch(base+path, {method, headers: {'Content-Type':'application/json','X-CSRF-Token':csrf}, body:JSON.stringify(data)});
      if (!response.ok) throw Error(path+' '+response.status);
      return response.status === 204 ? null : response.json();
    }
    const connection = await change('harnesses','POST',{name:'Browser PTY',executable:structured,terminalExecutable:interactive,credentialHome:home,allowAdHoc:true});
    if (!connection.capabilities.tty) throw Error('Missing terminal capability');
    await change('harnesses/'+connection.id+'/grants','PUT',{space,user});
    const record = await change('spaces/'+space+'/executions','POST',{connection:connection.id,message:'Start'});
    return {space,user,csrf,connection:connection.id,id:record.id};
  }, {home,structured,interactive});
  await page.getByRole('button',{name:'Repos',exact:true}).click();
  await page.getByRole('button',{name:'Sessions',exact:true}).click();
  await page.getByRole('button',{name:new RegExp(fixture.id.slice(0,8))}).click();
  await page.getByRole('button',{name:'Open terminal'}).click();
  const terminal = page.getByRole('region',{name:'Harness terminal'});
  await terminal.getByText('Connected',{exact:true}).waitFor();
  await terminal.locator('.xterm-accessibility-tree').getByText('READY',{exact:true}).waitFor();
  await page.keyboard.type('hello'); await page.keyboard.press('Enter');
  await terminal.locator('.xterm-accessibility-tree').getByText('Received hello',{exact:true}).waitFor();
  await terminal.locator('.xterm-accessibility-tree').getByText(/^\s*\d+ \d+\s*$/).waitFor();
  const terminalPID = async () => Number((await readFile(join(home,'terminal.pid'),'utf8')).trim());
  async function expectReaped(pid) {
    for (let attempt=0; attempt<100; attempt++) {
      try { process.kill(pid,0); } catch (error) { if (error.code==='ESRCH') return; throw error; }
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    throw Error('Harness process survived terminal closure');
  }
  const firstPID = await terminalPID();
  await page.getByRole('button',{name:'Close terminal'}).click();
  await expectReaped(firstPID);
  await page.getByRole('button',{name:'Open terminal'}).click();
  await terminal.locator('.xterm-accessibility-tree').getByText('READY',{exact:true}).waitFor();
  const pid = await terminalPID();
  await page.evaluate(async ({space,user,csrf,connection}) => {
    const response = await fetch('/api/v1/harnesses/'+connection+'/grants',{method:'DELETE',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({space,user})});
    if (!response.ok) throw Error('Revocation failed');
  }, fixture);
  await terminal.getByText('Disconnected',{exact:true}).waitFor();
  await expectReaped(pid);
  await page.getByRole('button',{name:'Close terminal'}).click();
  await page.getByRole('button',{name:'Open terminal'}).click();
  await terminal.getByRole('status').filter({hasText:/403/}).waitFor();
  assert.deepEqual(errors,[]);
  console.log('Stage 3 browser checks passed: Repo registration, actual checkout/status, durable comment, terminal I/O and size, disconnect cleanup, live grant revocation and denied reopen.');
} finally {
  await browser?.close();
  if(server && server.exitCode===null){server.kill('SIGTERM');await once(server,'exit');}
  await rm(home,{recursive:true,force:true});await rm(source,{recursive:true,force:true});
}
