"""Stage 2 durable channel, attribution, isolation and retention acceptance."""
from identity import Workspace
from pathlib import Path
import json
import uuid
import http.client
import io
import zipfile
import subprocess
import time


class Comms(Workspace):
    def test_channels_agents_retention(self):
        a = self.admin
        space = self.call('GET', 'spaces', session=a)[1]['spaces'][0]['id']
        base = f'spaces/{space}/'
        channel = self.call('GET', base+'channels', session=a)[1]['channels'][0]
        self.assertEqual(channel['name'], 'general')
        self.call('POST', base+'channels', {'name': 'planning'}, a)
        self.call('POST', base+'channels', {'name': '../escape'}, a, 400)
        self.call('POST', 'users', {'email':'other@test.org','password':self.password}, a)
        other = self.login('other@test.org')
        self.call('GET', base+'channels', session=other, expected=404)
        route = base+f"channels/{channel['id']}/messages"
        self.call('POST',base+'write',{'path':'plain.md','text':'untouched markdown'},a,204)
        identified=self.call('POST',base+'identify',{'path':'plain.md'},a)[1]
        self.assertTrue(identified['document']['id'])
        self.assertEqual(identified['text'],'untouched markdown')
        self.call('POST',base+'identify',{'path':'plain.md'},other,404)
        payload = {'body':'hello @someone **world**', 'nonce':str(uuid.uuid4())}
        message = self.call('POST', route, payload, a)[1]
        self.assertEqual(self.call('POST', route, payload, a)[1], message)
        self.call('POST', route, payload, other, 404)
        self.call('POST', route, payload, {'Cookie':a['Cookie']}, 403)
        agent = self.call('POST', 'agents', {'name':'Helper'}, a)[1]
        auth = {'Authorization':'Bearer '+agent['token']}
        self.call('POST', route, payload, auth, 401)
        self.call('PUT', base+'agents', {'id':agent['id']}, a, 204)
        self.assertEqual(self.call('GET',base+'agents',session=a)[1]['agents'][0]['id'],agent['id'])
        self.assertIn(agent['id'],[p['id'] for p in self.call('GET',base+'people',session=a)[1]['people']])
        m = self.call('POST', route, payload, auth)[1]
        self.assertEqual((m['author'],m['authorKind']), (agent['id'],'agent'))
        self.call('GET', base+'tree', session=auth, expected=401)
        self.call('DELETE', base+'agents', {'id':agent['id']}, a, 204)
        self.call('GET', route, session=auth, expected=401)
        self.stop()
        self.start()
        history = self.call('GET', route, session=a)[1]['messages']
        self.assertEqual(len(history), 2)
        root = Path(self.home.name)/'content/spaces'/space
        logs = list((root/'comms'/channel['id']).rglob('*.jsonl'))
        self.assertEqual(len(logs),1)
        expired = dict(message, id=str(uuid.uuid4()), sequence=0, created='2000-01-01T00:00:00Z')
        old = logs[0].parent/'2000-01-01.jsonl'
        old.write_text(json.dumps(expired)+'\n')
        self.call('GET', route, session=a)
        self.assertFalse(old.exists())
        self.assertEqual(self.call('GET', base+'tree', session=a)[1]['directories'], [])
        conn=http.client.HTTPConnection('127.0.0.1',self.port,timeout=5)
        conn.request('GET','/api/v1/'+base+'export',headers=a)
        response=conn.getresponse(); self.assertEqual(response.status,200)
        with zipfile.ZipFile(io.BytesIO(response.read())) as archive:
            self.assertFalse(any(n.startswith('comms/') for n in archive.namelist()))
        conn.close()
        repo=Path(self.home.name)/'runtime/history'/(space+'.git')
        for _ in range(50):
            result=subprocess.run(['git','--git-dir='+str(repo),'ls-tree','-r','--name-only','HEAD'],capture_output=True,text=True)
            if result.returncode==0: break
            time.sleep(.05)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(n.startswith('comms/') for n in result.stdout.splitlines()))
