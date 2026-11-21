"""Exercise the compiled server and assets in an isolated installation."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.request import urlopen


class Startup(unittest.TestCase):
    def test_same_origin(self):
        with tempfile.TemporaryDirectory() as home:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            server = subprocess.Popen(
                [".build/debug/tefter"],
                env=dict(os.environ, TEFTER_HOME=home, TEFTER_PORT=str(port)),
            )
            root = f"http://127.0.0.1:{port}"
            try:
                for attempt in range(100):
                    self.assertIsNone(server.poll())
                    try:
                        with urlopen(root + "/api/v1/ready", timeout=1) as response:
                            self.assertEqual(json.load(response), {"status": "ready"})
                        break
                    except OSError:
                        if attempt == 99:
                            raise
                        time.sleep(0.05)
                with urlopen(root + "/api/v1/health") as response:
                    self.assertEqual(json.load(response), {"status": "ok"})
                with urlopen(root + "/") as response:
                    self.assertIn(b"<title>Tefter</title>", response.read())
                self.assertEqual((Path(home) / "secrets").stat().st_mode & 0o777, 0o700)
            finally:
                server.terminate()
                server.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
