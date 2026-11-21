"""Run the real bootstrap CLI and HTTP membership flows against a temporary home."""
import http.client
import json
import os
import socket
import subprocess
import tempfile
import time
import unittest


class Workspace(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.env = dict(os.environ, TEFTER_HOME=self.home.name, TEFTER_PORT=str(self.port))
        self.password = "local test password"
        self.cli("bootstrap", "admin@example.test")
        self.start()
        self.admin = self.login("admin@example.test")

    def cli(self, command, email):
        subprocess.run([".build/debug/tefter", command, email], input=self.password + "\n",
                       text=True, env=self.env, check=True)

    def start(self):
        self.server = subprocess.Popen([".build/debug/tefter"], env=self.env)
        self.addCleanup(self.stop)
        for _ in range(100):
            self.assertIsNone(self.server.poll())
            try:
                self.call("GET", "ready")
                return
            except ConnectionError:
                time.sleep(.05)
        self.fail("Server failed to become ready")

    def stop(self):
        if self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=10)

    def call(self, method, path, body=None, session=None, expected=200, extra=None):
        headers = {"Content-Type": "application/json", **(session or {}), **(extra or {})}
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, "/api/v1/" + path, json.dumps(body) if body is not None else None, headers)
            res = conn.getresponse()
            data = res.read()
            self.assertEqual(res.status, expected, (method, path, data))
            return dict(res.getheaders()), json.loads(data) if data else None
        finally:
            conn.close()

    def login(self, email):
        headers, data = self.call("POST", "login", {"email": email, "password": self.password},
                                  extra={"X-Tefter-Login": "1"})
        cookie = {k.lower(): v for k, v in headers.items()}["set-cookie"]
        for flag in ["Secure", "HttpOnly", "SameSite=Strict"]:
            self.assertIn(flag, cookie)
        return {"Cookie": cookie.split(";")[0], "X-CSRF-Token": data["csrf"]}


class Identity(Workspace):
    def test_membership_and_recovery(self):
        a = self.admin
        user = self.call("POST", "users", {"email": "member@example.test", "password": self.password}, a)[1]["id"]
        b = self.login("member@example.test")
        personal = self.call("GET", "spaces", session=a)[1]["spaces"][0]["id"]
        self.call("GET", f"spaces/{personal}/people", session=b, expected=404)
        self.call("POST", "organizations", {"name": "denied"}, b, expected=403)
        self.call("POST", "organizations", {"name": "missing token"}, {"Cookie": a["Cookie"]}, expected=403)
        for name in ["North", "South"]:
            org = self.call("POST", "organizations", {"name": name}, a)[1]["id"]
            shared = self.call("POST", f"organizations/{org}/spaces", {"name": name}, a)[1]["id"]
            self.call("PUT", f"organizations/{org}/members", {"user": user}, a, 204)
            self.call("GET", f"spaces/{shared}/people", session=b, expected=404)
            self.call("PUT", f"spaces/{shared}/members", {"user": user}, a, 204)
            self.assertEqual(len(self.call("GET", f"spaces/{shared}/people", session=b)[1]["people"]), 2)
        self.stop()
        self.start()
        self.assertEqual(len(self.call("GET", "spaces", session=b)[1]["spaces"]), 3)
        self.call("DELETE", f"organizations/{org}/members", {"user": user}, a, 204)
        self.call("GET", f"spaces/{shared}/people", session=b, expected=404)
        self.stop()
        self.password = "new local password"
        self.cli("reset-password", "member@example.test")
        self.start()
        self.call("GET", "session", session=b, expected=401)
        self.login("member@example.test")


if __name__ == "__main__":
    unittest.main()
