import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp, rm, writeFile} from 'node:fs/promises';
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
  await page.getByText('harness resume, live streaming, cancellation and TTY are unavailable',{exact:false}).waitFor();
  assert.deepEqual(errors,[]);
  console.log('Stage 3 browser checks passed: Repo registration, actual checkout/status, durable comment, denied execution and honest capability UI.');
} finally {
  await browser?.close();
  if(server && server.exitCode===null){server.kill('SIGTERM');await once(server,'exit');}
  await rm(home,{recursive:true,force:true});await rm(source,{recursive:true,force:true});
}
