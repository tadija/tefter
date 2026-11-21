from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import unittest

from identity import Workspace


class Reconciliation(Workspace):
    def test_concurrent_edits_and_relocation_recovery(self):
        session = self.admin
        space = self.call("GET","spaces",session=session)[1]["spaces"][0]["id"]
        base = f"spaces/{space}/"
        root = Path(self.home.name)/"content/spaces"/space
        self.call("POST",base+"directory",{"path":"Records"},session,204)
        path = "Records/minutes.md"
        self.call("POST",base+"write",{"path":path,"text":"Original"},session,204)
        thread = self.call("POST",base+"comments",{"path":path,"body":"approval","revision":"initial"},session)[1]
        file = self.call("GET",base+"file?path="+path,session=session)[1]
        def write(text):
            conn = http.client.HTTPConnection("127.0.0.1",self.port)
            try:
                conn.request("POST","/api/v1/"+base+"write",json.dumps(dict(path=path,text=text,revision=file["document"]["revision"])),
                             {**session,"Content-Type":"application/json"})
                return conn.getresponse().status
            finally:
                conn.close()
        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(write,["First","Second"])),[204,409])
        after = self.call("GET",base+"file?path="+path,session=session)[1]
        self.stop()
        dest = "Records/approved.md"
        # Simulate the durable state left between rename and manifest replacement.
        (root/".tefter/relocation.json").write_text(json.dumps(dict(version=1,path=path,destination=dest,revision=after["document"]["revision"],directory=False)))
        (root/path).rename(root/dest)
        self.start()
        moved = self.call("GET",base+"file?path="+dest,session=session)[1]
        self.assertEqual(moved["document"]["id"],file["document"]["id"])
        revision = self.call("GET",base+"directory-revision?path=Records",session=session)[1]["id"]
        self.call("POST",base+"move-directory",{"path":"Records","destination":"Archive","revision":revision},session,204)
        restored = self.call("GET",base+"comments?path=Archive/approved.md",session=session)[1]
        self.assertEqual(restored,thread)
        self.call("POST",base+"comments",{"path":"Archive/approved.md","revision":"initial","body":"stale"},session,409)
        self.call("POST",base+"rescan",{},session,204)
        self.assertEqual(self.call("POST",base+"search",{"query":"approval"},session)[1]["hits"][0]["path"],"Archive/approved.md")


if __name__ == "__main__":
    unittest.main()
