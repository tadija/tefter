"""Stage 3 integration tests only; shared fixture does not run prior-stage tests."""
import unittest
import os
import shutil
import http.client
import json
import subprocess
import time
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
        self.call('GET',f'spaces/{sa}/repos/{own}',session=a,expected=404)
        self.call('PUT',f'repos/{own}/grants',{'space':sa},a,403)
        self.call('DELETE',f'repos/{central}/grants',{'space':sb},a,204)
        self.call('GET',f'spaces/{sb}/repos/{central}',session=b,expected=404)
        for location in ['https://secret@example.org/r','https://u:secret@example.org/r','https://example.org/r?token=secret','-x','relative/path','ext::sh attack']:
            self.call('POST','repos',dict(registration,location=location),a,400)
        self.stop()
        self.start()
        self.call('GET',f'spaces/{sb}/repos/{own}',session=b)
        self.assertEqual(self.call('GET','repos',session=a)[1]['repos'][0]['id'],central)

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
        self.call('POST',base+f'executions/{eid}/finish',{},a)
        self.stop(); self.start()
        durable = self.call('GET',base+f'executions/{eid}',session=a)[1]
        self.assertEqual(durable['status'],'finished')
        self.assertEqual(len(durable['conversation']),4)
        self.call('POST',base+f'executions/{eid}/messages',{'message':'Denied'},a,409)
        self.call('DELETE',f'harnesses/{hid}/grants',{'space':space,'user':durable['initiator']},a,204)
        self.call('GET',base+f'executions/{eid}',session=a,expected=403)


class Plugins(Workspace):
    def test_protocol_privilege_timeout_and_output_bounds(self):
        a = self.admin
        self.call('POST','users',{'email':'plugin-member@example.test','password':self.password},a)
        b = self.login('plugin-member@example.test')
        manifest = dict(version=1,name='Word count',executable=shutil.which('python3'),
            arguments=[str(Path('Examples/plugins/word-count.py').resolve())],
            commands=['word-count'],hooks=['word-count'],timeoutSeconds=2)
        self.call('POST','plugins',manifest,b,403)
        pid = self.call('POST','plugins',manifest,a)[1]['id']
        self.call('GET','plugins',session=b,expected=403)
        invoke = dict(version=1,point='command',name='word-count',text='one two three')
        self.call('POST',f'plugins/{pid}/invoke',invoke,b,403)
        result = self.call('POST',f'plugins/{pid}/invoke',invoke,a)[1]
        self.assertEqual(result['outcome'],'completed')
        self.assertEqual(result['response']['text'],'3')
        self.assertEqual(result['response']['id'],result['id'])
        self.call('POST',f'plugins/{pid}/invoke',dict(invoke,point='hook'),a)
        self.call('POST',f'plugins/{pid}/invoke',dict(invoke,name='arbitrary'),a,400)
        self.call('POST',f'plugins/{pid}/invoke',dict(invoke,version=2),a,400)
        self.call('POST',f'plugins/{pid}/invoke',invoke,{'Cookie':a['Cookie']},403)
        for code, expected in [("import time;time.sleep(10)",'timed-out'),
                               ("print('x'*100000)",'output-limit'),
                               ("print('not-json')",'invalid-response'),
                               ("raise SystemExit(7)",'failed')]:
            m = dict(manifest,arguments=['-c',code],timeoutSeconds=1)
            plugin = self.call('POST','plugins',m,a)[1]['id']
            started = time.monotonic()
            run = self.call('POST',f'plugins/{plugin}/invoke',invoke,a)[1]
            self.assertEqual(run['outcome'],expected)
            self.assertLess(time.monotonic()-started,3)
        self.stop(); self.start()
        self.assertTrue(any(p['id']==pid for p in self.call('GET','plugins',session=a)[1]['plugins']))


if __name__ == '__main__':
    unittest.main()
