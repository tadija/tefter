"""Stage 3 integration tests only; shared fixture does not run prior-stage tests."""
import unittest
import os
import shutil
import http.client
import json
import subprocess
import time
import threading
import io
from zipfile import ZipFile
from pathlib import Path
from identity import Workspace


class Repos(Workspace):
    def test_repo_ownership_and_explicit_grants(self):
        a = self.admin
        self.call('POST', 'users', {'email':'other@example.test','password':self.password}, a)
        b = self.login('other@example.test')
        sa = self.call('GET','spaces',session=a)[1]['spaces'][0]['id']
        sb = self.call('GET','spaces',session=b)[1]['spaces'][0]['id']
        registration = {'name':'Tefter','location':'https://example.org/tefter.git'}
        central = self.call('POST','repos',registration,a)[1]['id']
        own = self.call('POST','repos',dict(registration,space=sb),b)[1]['id']
        self.call('POST','repos',registration,b,403)
        self.call('POST','repos',dict(registration,space=sa),b,404)
        self.call('GET','repos',session=b,expected=403)
        self.assertEqual([r['id'] for r in self.call('GET','repos?space='+sb,session=b)[1]['repos']],[own])
        self.call('GET',f'spaces/{sb}/repos/{central}',session=b,expected=404)
        self.call('PUT',f'repos/{central}/grants',{'space':sb},b,403)
        self.call('PUT',f'repos/{central}/grants',{'space':sb},a,204)
        self.call('GET',f'spaces/{sb}/repos/{central}',session=b)
        self.call('GET',f'spaces/{sa}/repos/{own}/comments',session=a,expected=404)
        thread = self.call('POST',f'spaces/{sb}/repos/{own}/comments',
            {'path':'','revision':'initial','body':'Repo decision'},b)[1]
        self.call('POST',f'spaces/{sb}/repos/{own}/comments',
            {'path':'','revision':'initial','body':'Stale'},b,409)
        self.assertEqual(thread['comments'][0]['entity'],own)
        conn = http.client.HTTPConnection('127.0.0.1',self.port)
        conn.request('GET',f'/api/v1/spaces/{sb}/export',headers=b)
        with ZipFile(io.BytesIO(conn.getresponse().read())) as archive:
            self.assertIn(f'.tefter/repos/{own}.json',archive.namelist())
            self.assertIn(f'.tefter/comments/{own}.json',archive.namelist())
            self.assertNotIn(f'.tefter/repos/{central}.json',archive.namelist())
        conn.close()
        self.call('GET',f'spaces/{sa}/repos/{own}',session=a,expected=404)
        self.call('PUT',f'repos/{own}/grants',{'space':sa},a,403)
        self.call('POST',f'spaces/{sb}/write',{'path':'plan.md','text':'Plain document with a Repo reference'},b,204)
        links = self.call('GET',f'spaces/{sb}/integration-links?path=plan.md',session=b)[1]
        change = {'path':'plan.md','revision':links['revision'],'kind':'repo','target':central}
        linked = self.call('POST',f'spaces/{sb}/integration-links',change,b)[1]
        self.assertEqual(linked['links'][0]['title'],'Tefter')
        self.call('POST',f'spaces/{sb}/integration-links',change,b,409)
        document = self.call('GET',f'spaces/{sb}/file?path=plan.md',session=b)[1]
        self.assertEqual(document['text'],'Plain document with a Repo reference')
        self.call('POST',f'spaces/{sb}/move',{'path':'plan.md','destination':'moved.md','revision':document['document']['revision']},b,204)
        self.assertEqual(self.call('GET',f'spaces/{sb}/integration-links?path=moved.md',session=b)[1]['links'][0]['link']['id'],linked['links'][0]['link']['id'])
        self.call('DELETE',f'repos/{central}/grants',{'space':sb},a,204)
        self.call('GET',f'spaces/{sb}/repos/{central}',session=b,expected=404)
        revoked = self.call('GET',f'spaces/{sb}/integration-links?path=moved.md',session=b)[1]['links'][0]
        self.assertFalse(revoked['available'])
        self.assertNotIn('title',revoked)
        for location in ['https://secret@example.org/r','https://u:secret@example.org/r','https://example.org/r?token=secret','-x','relative/path','ext::sh attack']:
            self.call('POST','repos',dict(registration,location=location),a,400)
        ssh = self.call('POST','repos',dict(registration,space=sa,location='ssh://git@example.org/repo.git'),a)[1]['id']
        credential = {'privateKey':'PRIVATE-KEY-MARKER','knownHosts':'example.org ssh-ed25519 PINNED-HOST-MARKER'}
        self.call('PUT',f'spaces/{sa}/repos/{ssh}/credentials',credential,b,403)
        self.call('PUT',f'spaces/{sa}/repos/{ssh}/credentials',credential,a,204)
        secret = Path(self.home.name)/'secrets/git'/sa/ssh/'key'
        self.assertEqual(secret.read_text(),credential['privateKey'])
        self.assertEqual(secret.stat().st_mode & 0o077,0)
        conn = http.client.HTTPConnection('127.0.0.1',self.port)
        conn.request('GET',f'/api/v1/spaces/{sa}/export',headers=a)
        with ZipFile(io.BytesIO(conn.getresponse().read())) as archive:
            self.assertFalse(any(b'PRIVATE-KEY-MARKER' in archive.read(name) for name in archive.namelist()))
        conn.close()
        self.call('DELETE',f'spaces/{sa}/repos/{ssh}/credentials',{},a,204)
        self.assertFalse(secret.exists())
        self.stop()
        self.start()
        self.call('GET',f'spaces/{sb}/repos/{own}',session=b)
        self.assertEqual(self.call('GET','repos',session=a)[1]['repos'][0]['id'],central)


    def test_installation_repo_checkouts_are_separate_per_granted_space(self):
        a = self.admin
        source = Path(self.home.name)/'source'
        source.mkdir()
        def git(*args, at=source):
            return subprocess.check_output(['/usr/bin/git','-c','user.name=Test','-c','user.email=test@example.test',*args],cwd=at,text=True).strip()
        git('init','--initial-branch=main')
        (source/'file.md').write_text('Initial')
        git('add','.'); git('commit','-m','Initial')
        org = self.call('POST','organizations',{'name':'Stage 3'},a)[1]['id']
        spaces = [self.call('POST',f'organizations/{org}/spaces',{'name':name},a)[1]['id'] for name in ['One','Two']]
        user = self.call('POST','users',{'email':'repo-reader@example.test','password':self.password},a)[1]['id']
        b = self.login('repo-reader@example.test')
        self.call('PUT',f'organizations/{org}/members',{'user':user},a,204)
        self.call('PUT',f'spaces/{spaces[0]}/members',{'user':user},a,204)
        rid = self.call('POST','repos',{'name':'Central','location':str(source)},a)[1]['id']
        for space in spaces:
            self.call('PUT',f'repos/{rid}/grants',{'space':space},a,204)
            self.call('POST',f'spaces/{space}/repos/{rid}/checkout',{},a)
        self.call('GET',f'spaces/{spaces[0]}/repos/{rid}/status',session=b)
        self.call('GET',f'spaces/{spaces[1]}/repos/{rid}/status',session=b,expected=404)
        self.call('POST',f'spaces/{spaces[0]}/repos/{rid}/checkout',{},b,403)
        self.call('POST','repos',{'space':spaces[0],'name':'Denied','location':str(source)},b,403)
        one = Path(self.home.name)/'repositories'/spaces[0]/rid/'checkout'
        two = Path(self.home.name)/'repositories'/spaces[1]/rid/'checkout'
        original = git('rev-parse','HEAD',at=two)
        (one/'file.md').write_text('Only checkout one')
        git('add','.',at=one);git('commit','-m','One changed',at=one)
        self.assertEqual(git('rev-parse','HEAD',at=two),original)
        self.assertNotEqual(git('rev-parse','HEAD',at=one),original)
        self.call('DELETE',f'repos/{rid}/grants',{'space':spaces[0]},a,204)
        self.call('GET',f'spaces/{spaces[0]}/repos/{rid}/status',session=b,expected=404)


class Harness(Workspace):
    def call(self, method, path, body=None, session=None, expected=200, extra=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=150)
        try:
            conn.request(method, "/api/v1/"+path, json.dumps(body) if body is not None else None,
                         {"Content-Type":"application/json", **(session or {}), **(extra or {})})
            response = conn.getresponse()
            raw = response.read()
            self.assertEqual(response.status, expected, (path, raw))
            return dict(response.getheaders()), json.loads(raw) if raw else None
        finally:
            conn.close()

    def test_real_codex_conversation_and_execution_policy(self):
        executable = os.environ.get("TEFTER_TEST_CODEX") or shutil.which("codex")
        credentials = os.environ.get("TEFTER_TEST_CODEX_HOME", os.path.expanduser("~/.codex"))
        if not executable or not Path(credentials).is_dir():
            self.skipTest("Real Codex executable and credential home required")
        a = self.admin
        space = self.call('GET','spaces',session=a)[1]['spaces'][0]['id']
        base = f'spaces/{space}/'
        harness = self.call('POST','harnesses', {'name':'Real Codex', 'executable':executable,
            'credentialHome':credentials, 'allowAdHoc':True}, a)[1]
        hid = harness['id']
        self.assertFalse(harness['capabilities']['resume'])
        self.assertFalse(harness['capabilities']['tty'])
        source = Path(self.home.name)/'git-source'
        source.mkdir()
        def git(*args, at=source):
            return subprocess.check_output(['/usr/bin/git','-c','user.name=Test','-c','user.email=test@example.test',*args],cwd=at,text=True).strip()
        git('init','--initial-branch=main')
        (source/'note.md').write_text('Original')
        git('add','.'); git('commit','-m','Initial')
        original = git('rev-parse','HEAD')
        remote = Path(self.home.name)/'remote.git'
        git('clone','--bare',str(source),str(remote))
        rid = self.call('POST','repos',{'space':space,'name':'Git test','location':str(remote)},a)[1]['id']
        self.call('POST',base+f'repos/{rid}/checkout',{},a)
        request = {'connection':hid,'repo':rid,'message':'Do not use tools. Reply exactly: stage-three-ready'}
        self.call('POST',base+'executions',request,a,403)
        self.call('PUT',f'harnesses/{hid}/grants',{'space':space,'user':self.call('GET','session',session=a)[1]['user']},a,204)
        record = self.call('POST',base+'executions',request,a)[1]
        self.assertEqual(record['status'],'completed',record)
        self.assertIn('stage-three-ready',record['conversation'][-1]['text'])
        eid = record['id']
        self.call('POST',base+f'executions/{eid}/worktree',{},a)
        checkout = Path(self.home.name)/'repositories'/space/rid/'checkout'
        worktree = checkout.parent/('session-'+eid)
        (worktree/'note.md').write_text('Reviewed change')
        git('add','.',at=worktree); git('commit','-m','Session change',at=worktree)
        review = self.call('GET',base+f'executions/{eid}/review',session=a)[1]
        self.assertIn('Reviewed change',review['diff'])
        self.assertEqual(git('rev-parse','HEAD',at=checkout),original)
        self.assertEqual(git('show-ref',at=remote),original+' refs/heads/main')
        approval = dict(approve=False,head=review['head'],base=review['base'])
        self.call('POST',base+f'executions/{eid}/merge',approval,a,400)
        self.call('POST',base+f'executions/{eid}/merge',dict(approval,approve=True,base='stale'),a,409)
        self.call('POST',base+f'executions/{eid}/merge',dict(approval,approve=True),a)
        self.assertEqual(git('rev-parse','HEAD',at=checkout),review['head'])
        self.assertEqual(git('show-ref',at=remote),original+' refs/heads/main')
        after = self.call('GET',base+f'executions/{eid}/review',session=a)[1]
        self.call('POST',base+f'executions/{eid}/push',dict(approve=True,head=after['head'],base=after['base']),a)
        self.assertIn('refs/heads/tefter/'+eid,git('show-ref',at=remote))
        record = self.call('POST',base+f'executions/{eid}/messages',{'message':'Do not use tools. What exact phrase did you just reply with?'},a)[1]
        self.assertEqual(record['status'],'completed')
        self.assertIn('stage-three-ready',record['conversation'][-1]['text'])
        self.assertEqual(len(record['conversation']),4)
        self.call('POST',base+f'executions/{eid}/comments',{'path':'','revision':'initial','body':'Execution decision'},a)
        self.call('POST',base+f'executions/{eid}/finish',{},a)
        self.stop(); self.start()
        durable = self.call('GET',base+f'executions/{eid}',session=a)[1]
        self.assertEqual(durable['status'],'finished')
        self.assertEqual(len(durable['conversation']),4)
        self.call('POST',base+f'executions/{eid}/messages',{'message':'Denied'},a,409)
        self.call('DELETE',f'harnesses/{hid}/grants',{'space':space,'user':durable['initiator']},a,204)
        self.call('GET',base+f'executions/{eid}',session=a,expected=403)
        self.call('GET',base+f'executions/{eid}/comments',session=a,expected=403)



class ExecutionRevocation(Workspace):
    def test_running_turn_does_not_deliver_output_after_grant_revocation(self):
        # Controlled protocol fixture tests the revocation race only. The separate
        # real Codex test is required evidence for harness acceptance.
        a = self.admin
        user = self.call('GET','session',session=a)[1]['user']
        space = self.call('GET','spaces',session=a)[1]['spaces'][0]['id']
        script = Path(self.home.name)/'fixture-harness'
        script.write_text('#!'+shutil.which('python3')+'\nimport time,json\ntime.sleep(1)\nprint(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":"DO-NOT-DELIVER"}}))\n')
        script.chmod(0o700)
        hid = self.call('POST','harnesses',dict(name='Revocation fixture',executable=str(script),credentialHome=self.home.name,allowAdHoc=True),a)[1]['id']
        grant = {'space':space,'user':user}
        self.call('PUT',f'harnesses/{hid}/grants',grant,a,204)
        responses = []
        failures = []
        def start():
            try: responses.append(self.call('POST',f'spaces/{space}/executions',{'connection':hid,'message':'test'},a,403))
            except Exception as error: failures.append(error)
        thread = threading.Thread(target=start)
        thread.start()
        for _ in range(50):
            records = self.call('GET',f'spaces/{space}/executions',session=a)[1]['sessions']
            if records: break
            time.sleep(.01)
        self.assertTrue(records)
        self.assertEqual(records[0]['status'],'running')
        self.call('DELETE',f'harnesses/{hid}/grants',grant,a,204)
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures,[])
        self.assertEqual(len(responses),1)
        self.assertNotIn('DO-NOT-DELIVER',json.dumps(responses))
        self.call('GET',f"spaces/{space}/executions/{records[0]['id']}",session=a,expected=403)


class DeploymentBoundary(Workspace):
    def test_stage3_private_roots_cannot_be_served_as_web_assets(self):
        self.stop()
        for name in ['repositories']:
            directory = Path(self.home.name)/name
            directory.mkdir(exist_ok=True)
            (directory/'index.html').write_text('Private')
            run = subprocess.run(['.build/debug/tefter'], env=dict(self.env,TEFTER_WEB=str(directory)),capture_output=True,timeout=5)
            self.assertNotEqual(run.returncode,0)
            self.assertIn(b'TEFTER_WEB',run.stderr)


if __name__ == '__main__':
    unittest.main()
