import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {mkdtemp,rm} from 'node:fs/promises';
import net from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright-core';

const cwd=fileURLToPath(new URL('../..',import.meta.url));
const home=await mkdtemp(join(tmpdir(),'tefter-audio-'));
const probe=net.createServer().listen(0,'127.0.0.1');await once(probe,'listening');
const port=probe.address().port;await new Promise(r=>probe.close(r));
const origin='http://127.0.0.1:'+port, password='audio acceptance password';
const env={...process.env,TEFTER_HOME:home,TEFTER_PORT:String(port)};
const binary=process.env.TEFTER_TEST_BINARY || '.build/debug/tefter';
let server;
const browsers=[];
try {
  const cli=spawnSync(binary,['bootstrap','one@example.test'],{cwd,env,input:password+'\n'});
  assert.equal(cli.status,0,cli.stderr.toString());
  server=spawn(binary,[],{cwd,env,stdio:'ignore'});
  for(let i=0;i<100;i++){
    if(await fetch(origin+'/api/v1/ready').then(r=>r.ok,()=>false))break;
    await new Promise(r=>setTimeout(r,50));
  }
  async function login(email){
    const r=await fetch(origin+'/api/v1/login',{method:'POST',headers:{'Content-Type':'application/json','X-Tefter-Login':'1'},body:JSON.stringify({email,password})});
    assert.equal(r.status,200);return {cookie:r.headers.get('set-cookie').split(';')[0],...await r.json()};
  }
  const a=await login('one@example.test');
  async function api(path,body,method='POST',session=a){
    const r=await fetch(origin+'/api/v1/'+path,{method,headers:{'Content-Type':'application/json','Cookie':session.cookie,'X-CSRF-Token':session.csrf},body:body===undefined?undefined:JSON.stringify(body)});
    assert.ok(r.ok,`${path}: ${r.status} ${await (r.ok?Promise.resolve(''):r.text())}`);
    return r.status===204?null:r.json();
  }
  const second=await api('users',{email:'two@example.test',password});
  const b=await login('two@example.test');
  const org=await api('organizations',{name:'Audio'});
  const space=(await api(`organizations/${org.id}/spaces`,{name:'Audio'})).id;
  await api(`organizations/${org.id}/members`,{user:second.id},'PUT');
  await api(`spaces/${space}/members`,{user:second.id},'PUT');
  const errors=[];
  async function pageFor(session){
    // Independent browser processes make this a real two-endpoint WebRTC test.
    const browser=await chromium.launch({channel:'chrome',headless:true,executablePath:process.env.TEFTER_TEST_CHROME || undefined,args:['--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream','--autoplay-policy=no-user-gesture-required']});
    browsers.push(browser);
    const context=await browser.newContext({permissions:['microphone']});
    await context.addCookies([{name:'tefter',value:session.cookie.split('=')[1],url:origin,httpOnly:true,sameSite:'Strict'}]);
    await context.addInitScript(()=>{
      window.audioConnections=[];
      window.audioMicrophones=[];
      const capture=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia=async constraints=>{const stream=await capture(constraints);window.audioMicrophones.push(stream);return stream;};
      const Native=window.RTCPeerConnection;
      window.RTCPeerConnection=class extends Native {constructor(...args){super(...args);window.audioConnections.push(this);}};
    });
    const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
    await page.goto(origin);
    await page.getByLabel('Space',{exact:true}).selectOption(space);
    await page.getByRole('button',{name:'Comms',exact:true}).click();
    await page.getByRole('button',{name:'Join audio',exact:true}).waitFor();
    return page;
  }
  const one=await pageFor(a), two=await pageFor(b);
  await one.getByRole('button',{name:'Join audio',exact:true}).click();
  await two.getByRole('button',{name:'Join audio',exact:true}).click();
  const media=[];
  for(const page of [one,two]){
    await page.waitForFunction(()=>document.querySelectorAll('[aria-label="Audio participants"] li').length===2);
    let snapshot=[];
    for(let attempt=0;attempt<150;attempt++) {
      snapshot=await page.evaluate(async()=>{
        const result=[];
        for(const pc of window.audioConnections) {
          if(pc.connectionState !== 'connected')continue;
          for(const stat of (await pc.getStats()).values())
            if(stat.type==='inbound-rtp' && stat.kind==='audio')result.push({bytes:stat.bytesReceived,energy:stat.totalAudioEnergy});
        }
        return result;
      });
      if(snapshot.some(s=>s.bytes>1000 && s.energy>0))break;
      await new Promise(r=>setTimeout(r,100));
    }
    media.push(snapshot);
    assert.equal(await page.evaluate(()=>window.audioConnections.some(pc=>pc.getSenders().some(s=>s.track?.kind==='video'))),false);
  }
  assert.ok(media.every(stats=>stats.some(s=>s.bytes>1000 && s.energy>0)), 'Active media statistics required: '+JSON.stringify(media));
  for(const page of [one,two]) assert.ok(await page.evaluate(()=>window.audioConnections.some(pc=>pc.connectionState==='connected')), 'Live peer connection required');
  await one.getByRole('button',{name:'Mute microphone',exact:true}).click();
  await two.getByText('one@example.test · muted',{exact:true}).waitFor();
  assert.equal(await one.evaluate(()=>window.audioConnections.filter(pc=>pc.connectionState==='connected').every(pc=>pc.getSenders().filter(s=>s.track).every(s=>!s.track.enabled))),true);
  await one.getByRole('button',{name:'Unmute microphone',exact:true}).click();
  await two.getByText('one@example.test · microphone on',{exact:true}).waitFor();
  await two.getByRole('button',{name:'Leave audio',exact:true}).click();
  await one.waitForFunction(()=>document.querySelectorAll('[aria-label="Audio participants"] li').length===1);
  assert.equal(await two.evaluate(()=>window.audioConnections.every(pc=>pc.connectionState==='closed')),true);
  assert.equal(await two.evaluate(()=>window.audioMicrophones.every(s=>s.getTracks().every(t=>t.readyState==='ended'))),true);
  await two.getByRole('button',{name:'Join audio',exact:true}).click();
  await one.waitForFunction(()=>document.querySelectorAll('[aria-label="Audio participants"] li').length===2);
  // Revocation closes the revoked socket and surviving peers' media connections.
  await api(`spaces/${space}/members`,{user:second.id},'DELETE');
  await two.getByRole('button',{name:'Join audio',exact:true}).waitFor();
  await one.waitForFunction(()=>document.querySelectorAll('[aria-label="Audio participants"] li').length===1);
  await one.waitForFunction(()=>window.audioConnections.every(pc=>pc.connectionState==='closed'));
  await one.getByRole('button',{name:'Leave audio',exact:true}).click();
  assert.equal(await two.evaluate(()=>window.audioMicrophones.every(s=>s.getTracks().every(t=>t.readyState==='ended'))),true);
  await one.getByRole('button',{name:'Join audio',exact:true}).click();
  await one.getByRole('button',{name:'Mute microphone',exact:true}).waitFor();
  server.kill('SIGSTOP');
  await one.getByText('Audio signaling lost. Media stopped; join again to reconnect.',{exact:true}).waitFor();
  assert.equal(await one.evaluate(()=>window.audioMicrophones.every(s=>s.getTracks().every(t=>t.readyState==='ended'))),true);
  server.kill('SIGCONT');
  assert.deepEqual(errors,[]);
  console.log('Audio E2E passed: two browser processes exchanged actual audio RTP with nonzero energy; join/leave, mute/unmute, rejoin, membership eviction, microphone cleanup and signaling-loss shutdown passed. Media:',JSON.stringify(media));
} finally {
  await Promise.all(browsers.map(b=>b.close()));
  if(server && server.exitCode===null){server.kill('SIGCONT');server.kill('SIGTERM');await once(server,'exit');}
  await rm(home,{recursive:true,force:true});
}
