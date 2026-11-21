"""Additive operational migration, configured retention and managed-path safety."""
from identity import Workspace
from pathlib import Path
from datetime import datetime, timedelta, timezone
import json
import sqlite3
import subprocess
import uuid


class Compatibility(Workspace):
    def test_stage1_upgrade_and_configured_retention(self):
        a=self.admin
        space=self.call('GET','spaces',session=a)[1]['spaces'][0]['id']
        base=f'spaces/{space}/'
        self.call('POST',base+'write',{'path':'existing.md','text':'survives upgrade'},a,204)
        self.stop()
        home=Path(self.home.name)
        # Stage 1 database layout and an existing valid session are retained.
        with sqlite3.connect(home/'runtime/tefter.sqlite') as db:
            for table in ['channel_cursors','agent_grants','agents','shares']:
                db.execute('DROP TABLE '+table)
            db.execute('PRAGMA user_version=1')
        (home/'config/server.json').write_text(json.dumps({'version':1,'settings':{'TEFTER_COMMS_RETENTION_DAYS':'1'}}))
        self.start()
        self.assertEqual(self.call('GET',base+'file?path=existing.md',session=a)[1]['text'],'survives upgrade')
        channel=self.call('GET',base+'channels',session=a)[1]['channels'][0]['id']
        route=base+f'channels/{channel}/messages'
        message=self.call('POST',route,{'body':'retained','nonce':str(uuid.uuid4())},a)[1]
        logs=list((home/'content/spaces'/space/'comms'/channel).rglob('*.jsonl'))
        old=dict(message,id=str(uuid.uuid4()),sequence=0,created=(datetime.now(timezone.utc)-timedelta(days=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))
        oldpath=logs[0].parent/'old.jsonl'; oldpath.write_text(json.dumps(old)+'\n')
        self.assertEqual(len(self.call('GET',route,session=a)[1]['messages']),1)
        self.assertFalse(oldpath.exists())
        with sqlite3.connect(home/'runtime/tefter.sqlite') as db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0],2)
        # Expiring every file must not reset the durable sequence high-water mark.
        logs[0].write_text(json.dumps(dict(message,created=old['created']))+'\n')
        self.assertEqual(self.call('GET',route,session=a)[1]['messages'],[])
        following=self.call('POST',route,{'body':'after expiry','nonce':str(uuid.uuid4())},a)[1]
        self.assertGreater(following['sequence'],message['sequence'])
        self.assertEqual(self.call('GET',route+'?after='+str(message['sequence']),session=a)[1]['messages'][0]['id'],following['id'])
        self.call('POST',base+'write',{'path':'comms/hijack.md','text':'no'},a,400)
        self.call('POST',base+'directory',{'path':'nested'},a,204)
        self.call('POST',base+'directory',{'path':'nested/comms'},a,204)
        self.call('POST',base+'write',{'path':'nested/comms/ordinary.md','text':'ordinary document'},a,204)
        self.assertIn('nested/comms/ordinary.md',[d['path'] for d in self.call('GET',base+'tree',session=a)[1]['documents']])
        self.stop()
        # A pre-existing Stage 1 root comms folder must never be silently hidden.
        (home/'content/spaces'/space/'.tefter/channels.json').unlink()
        result=subprocess.run(['.build/debug/tefter'],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('pre-existing comms directory',result.stderr)
