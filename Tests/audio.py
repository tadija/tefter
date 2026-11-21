"""Audio-only signaling/security tests; earlier-stage suites are not run."""
from identity import Workspace
from live import SocketClient
import json
import uuid
import unittest
from pathlib import Path

class AudioSecurity(Workspace):
    def test_audio_auth_csrf_origin_and_room_isolation(self):
        a=self.admin
        space=self.call('GET','spaces',session=a)[1]['spaces'][0]['id']
        base=f'spaces/{space}/'
        channel=self.call('GET',base+'channels',session=a)[1]['channels'][0]['id']
        other=self.call('POST',base+'channels',{'name':'other'},a)[1]['channels'][-1]['id']
        uid=self.call('POST','users',{'email':'outsider@example.test','password':self.password},a)[1]['id']
        b=self.login('outsider@example.test')
        route=base+f'channels/{channel}/audio'
        self.call('GET',route,session=b,expected=404)
        self.call('GET',route,expected=401)
        config=self.call('GET',route,session=a)[1]
        self.assertEqual(config['iceServers'],[])
        self.assertEqual(config['maximumParticipants'],6)
        ice=Path(self.home.name)/'secrets/audio-ice.json'
        servers=[{'urls':['turn:relay.example.test:3478'],'username':'test-user','credential':'TEST-TURN-CREDENTIAL'}]
        ice.write_text(json.dumps(servers));ice.chmod(0o644)
        self.call('GET',route,session=a,expected=500)
        ice.chmod(0o600)
        self.assertEqual(self.call('GET',route,session=a)[1]['iceServers'],servers)
        self.call('GET',route,session=b,expected=404)
        ice.unlink()
        def connect(channel=channel,session=a,origin=None):
            headers=dict(session,Origin=origin or f'http://127.0.0.1:{self.port}')
            client=SocketClient(self.port,base+f'channels/{channel}/audio/live',headers)
            self.addCleanup(client.close)
            return client
        self.assertNotEqual(connect(session=b).status,101)
        self.assertNotEqual(connect(origin='https://evil.example').status,101)
        bad=connect();self.assertEqual(bad.status,101)
        bad.send({'type':'join','csrf':'invalid'})
        while bad.receive() is not None: pass
        one=connect();two=connect(channel=other)
        for client in [one,two]: client.send({'type':'join','csrf':a['X-CSRF-Token']})
        def joined(client):
            for _ in range(20):
                event=client.receive()
                if event and event.get('participants'): return event
            self.fail('No participant roster')
        left,right=joined(one),joined(two)
        self.assertEqual(len(left['participants']),1)
        self.assertEqual(len(right['participants']),1)
        self.assertNotEqual(left['id'],right['id'])
        # A peer leaving during negotiation must not eject a valid sender.
        one.send({'type':'offer','csrf':a['X-CSRF-Token'],'target':str(uuid.uuid4()),'payload':'stale-offer'})
        one.send({'type':'mute','csrf':a['X-CSRF-Token'],'muted':True})
        for _ in range(20):
            event=one.receive()
            self.assertIsNotNone(event)
            if event['participants'] and event['participants'][0]['muted']: break
        else: self.fail('Sender was lost after a stale signal')
        # A target ID from another channel is not a routing capability.
        one.send({'type':'offer','csrf':a['X-CSRF-Token'],'target':right['id'],'payload':'private-offer'})
        while one.receive() is not None: pass
        agent=self.call('POST','agents',{'name':'Comms only'},a)[1]
        self.call('PUT',base+'agents',{'id':agent['id']},a,204)
        self.call('GET',route,session={'Authorization':'Bearer '+agent['token']},expected=403)
        # Logout actively evicts this session's remaining room participant.
        self.call('POST','logout',{},a,204)
        while two.receive() is not None: pass

if __name__=='__main__': unittest.main()
