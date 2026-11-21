import os
from pathlib import Path
import subprocess
import socket
import unittest
import uuid

from identity import Workspace


class Boundaries(Workspace):
    def test_files_preview_and_private_history(self):
        a = self.admin
        space = self.call("GET","spaces",session=a)[1]["spaces"][0]["id"]
        base = f"spaces/{space}/"
        root = Path(self.home.name)/"content/spaces"/space
        self.call("POST",base+"directory",{"path":"research"},a,204)
        self.call("POST",base+"write",{"path":"../outside.md","text":"sample"},a,400)
        outside = Path(self.home.name)/"private.md"
        outside.write_text("private")
        os.symlink(outside, root/"external.md")
        self.call("GET",base+"tree",session=a,expected=409)
        (root/"external.md").unlink()
        self.assertEqual(outside.read_text(),"private")
        entity = str(uuid.uuid4())
        path = "research/local.md"
        probe = socket.socket()
        self.addCleanup(probe.close)
        probe.bind(("127.0.0.1",0))
        probe.listen()
        probe.settimeout(.2)
        text = f"---\ntype: url\nid: {entity}\ntitle: Local\nurl: http://127.0.0.1:{probe.getsockname()[1]}/\n---\nNotes"
        self.call("POST",base+"write",{"path":path,"text":text},a,204)
        self.call("POST",base+"preview?path="+path,{},a,422)
        with self.assertRaises(TimeoutError):
            probe.accept()
        self.stop()
        self.start()
        repo = Path(self.home.name)/"runtime/history"/(space+".git")
        import time
        for _ in range(100):
            result = subprocess.run(["git","--git-dir",str(repo),"ls-tree","-r","--name-only","HEAD"],capture_output=True,text=True)
            if result.returncode == 0 and path in result.stdout:
                break
            time.sleep(.05)
        self.assertIn(path,result.stdout)
        self.assertNotIn("tefter.sqlite",result.stdout)
        self.assertNotIn("private.md",result.stdout)


if __name__ == "__main__":
    unittest.main()
