import http.client
import io
import json
from pathlib import Path
import sqlite3
import unittest
from zipfile import ZipFile

from identity import Workspace


class Shared(Workspace):
    def test_member_writes_folder_export_and_session_controls(self):
        a = self.admin
        uid = self.call("POST","users",{"email":"writer@example.test","password":self.password},a)[1]["id"]
        b = self.login("writer@example.test")
        org = self.call("POST","organizations",{"name":"Studio"},a)[1]["id"]
        space = self.call("POST",f"organizations/{org}/spaces",{"name":"Work"},a)[1]["id"]
        base = f"spaces/{space}/"
        self.call("PUT",f"organizations/{org}/members",{"user":uid},a,204)
        self.call("PUT",base+"members",{"user":uid},a,204)
        for folder in ["Meeting","Plans"]:
            self.call("POST",base+"directory",{"path":folder},b,204)
            self.call("POST",base+"write",{"path":folder+"/notes.md","text":"# "+folder},b,204)
        thread = self.call("POST",base+"comments",{"path":"Meeting/notes.md","revision":"initial","body":"Review"},b)[1]
        self.assertEqual(thread["comments"][0]["author"],uid)
        self.call("POST",base+"comments",{"path":"Meeting/notes.md","revision":thread["revision"],"id":thread["comments"][0]["id"],"body":"Overwrite"},a,403)
        self.call("POST",base+"comments",{"path":"Plans/notes.md","revision":"initial","body":"Not selected"},a)
        settings = self.call("GET",base+"views",session=a)[1]
        settings["defaults"] = {"Meeting":"Tasks","Plans":"URLs"}
        settings["saved"] = {"Board":"Kanban"}
        self.call("PUT",base+"views",settings,b)
        self.call("PUT",base+"views",settings,a,409)
        conn = http.client.HTTPConnection("127.0.0.1",self.port)
        conn.request("GET","/api/v1/"+base+"export?folder=Meeting",headers=b)
        with ZipFile(io.BytesIO(conn.getresponse().read())) as z:
            self.assertIn("Meeting/notes.md",z.namelist())
            self.assertNotIn("Plans/notes.md",z.namelist())
            self.assertEqual(json.loads(z.read(".tefter/views.json"))["defaults"],{"Meeting":"Tasks"})
            files = [n for n in z.namelist() if n.startswith(".tefter/comments/")]
            self.assertEqual(len(files),1)
            self.assertEqual(json.loads(z.read(files[0]))["comments"][0]["author"],uid)
        conn.close()
        self.call("DELETE",base+"members",{"user":uid},a,204)
        self.call("GET",base+"file?path=Meeting/notes.md",session=b,expected=404)
        self.call("GET",base+"export",session=b,expected=404)
        self.stop()
        with sqlite3.connect(Path(self.home.name)/"runtime/tefter.sqlite") as db:
            db.execute("UPDATE sessions SET expires=0 WHERE user=?",(uid,))
        self.start()
        self.call("GET","session",session=b,expected=401)
        login = {"email":"writer@example.test","password":"incorrect"}
        for _ in range(8):
            self.call("POST","login",login,extra={"X-Tefter-Login":"1"},expected=401)
        self.call("POST","login",login,extra={"X-Tefter-Login":"1"},expected=429)


if __name__ == "__main__":
    unittest.main()
