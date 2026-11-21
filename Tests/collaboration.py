import http.client
import io
import json
import sqlite3
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

from identity import Workspace


class Collaboration(Workspace):
    def test_comment_search_export_restore(self):
        a = self.admin
        space = self.call("GET", "spaces", session=a)[1]["spaces"][0]["id"]
        base = f"spaces/{space}/"
        self.call("POST", base + "write", {"path":"notes.md","text":"# Notes"}, a, 204)
        self.call("POST", "users", {"email":"guest@example.test","password":self.password}, a)
        guest = self.login("guest@example.test")
        personal = self.call("GET", "spaces", session=guest)[1]["spaces"][0]["id"]
        c = self.call("POST", base + "comments", {"path":"notes.md","body":"marigold","revision":"initial"}, a)[1]
        self.call("POST", base + "comments", {"path":"notes.md","body":"reply","parent":c["comments"][0]["id"],"revision":c["revision"]}, a)
        self.assertEqual(len(self.call("POST", base+"search", {"query":"marigold"}, a)[1]["hits"]),1)
        self.assertEqual(self.call("POST", f"spaces/{personal}/search", {"query":"marigold","allSpaces":True}, guest)[1]["hits"],[])
        self.call("GET", base+"export", session=guest, expected=404)
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", "/api/v1/"+base+"export", headers=a)
        with zipfile.ZipFile(io.BytesIO(conn.getresponse().read())) as archive:
            self.assertEqual(archive.read("notes.md"),b"# Notes")
            self.assertTrue(any(n.startswith(".tefter/comments/") for n in archive.namelist()))
            self.assertFalse(any("sqlite" in n for n in archive.namelist()))
        conn.close()
        config = Path(self.home.name)/"config/server.json"
        config.write_text(json.dumps({"version":1,"settings":{"TEFTER_HOST":"127.0.0.1"}}))
        secret = Path(self.home.name)/"secrets/smtp-password"
        secret.write_text("synthetic restore fixture")
        secret.chmod(0o600)
        self.stop()
        with tempfile.TemporaryDirectory() as tmp:
            backup, restored = [Path(tmp)/name for name in ["backup","restored"]]
            subprocess.run(["python3","Scripts/instance.py","backup",self.home.name,backup],check=True)
            subprocess.run(["python3","Scripts/instance.py","restore",backup,restored],check=True)
            self.assertEqual((restored/"config/server.json").read_bytes(), config.read_bytes())
            self.assertEqual((restored/"secrets/smtp-password").read_bytes(), secret.read_bytes())
            with sqlite3.connect(restored/"runtime/tefter.sqlite") as db:
                db.execute("DROP TABLE search")
            self.env["TEFTER_HOME"] = str(restored)
            self.start()
            restored_session = self.login("admin@example.test")
            thread = self.call("GET", base+"comments?path=notes.md",session=restored_session)[1]
            self.assertEqual([c["body"] for c in thread["comments"]], ["marigold","reply"])
            self.assertEqual(len(self.call("POST", base+"search",{"query":"marigold"},restored_session)[1]["hits"]),1)
            self.stop()
            (backup/"instance"/"secrets/smtp-password").write_text("changed")
            failed = subprocess.run(["python3","Scripts/instance.py","restore",backup,Path(tmp)/"rejected"],capture_output=True)
            self.assertNotEqual(failed.returncode,0)
            self.assertFalse((Path(tmp)/"rejected").exists())


if __name__ == "__main__":
    unittest.main()
