"""Stage 2 durable channel, attribution, isolation and retention acceptance."""
from identity import Workspace
from pathlib import Path
import json
import uuid


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
        payload = {'body':'hello @someone **world**', 'nonce':str(uuid.uuid4())}
        message = self.call('POST', route, payload, a)[1]
        self.assertEqual(self.call('POST', route, payload, a)[1], message)
        self.call('POST', route, payload, other, 404)
        self.call('POST', route, payload, {'Cookie':a['Cookie']}, 403)
        agent = self.call('POST', 'agents', {'name':'Helper'}, a)[1]
        auth = {'Authorization':'Bearer '+agent['token']}
        self.call('POST', route, payload, auth, 401)
        self.call('PUT', base+'agents', {'id':agent['id']}, a, 204)
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
