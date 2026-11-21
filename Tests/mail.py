import json
from pathlib import Path
import re
import socketserver
import ssl
import subprocess
import tempfile
import threading
import unittest

from identity import Workspace


class Mail(Workspace):
    def test_invitation_and_password_rotation(self):
        self.stop()
        with tempfile.TemporaryDirectory() as temp:
            cert, key = Path(temp)/"cert.pem", Path(temp)/"key.pem"
            subprocess.run(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","1","-subj","/CN=localhost",
                            "-addext","subjectAltName=IP:127.0.0.1","-keyout",key,"-out",cert],check=True,capture_output=True)
            message = bytearray()
            class Mailbox(socketserver.StreamRequestHandler):
                def handle(self):
                    self.wfile.write(b"220 mail.test ESMTP\r\n")
                    while line := self.rfile.readline():
                        verb = line.split(maxsplit=1)[0].upper()
                        if verb == b"EHLO": reply = b"250 mail.test\r\n"
                        elif verb == b"DATA":
                            self.wfile.write(b"354 End with dot\r\n")
                            while (line := self.rfile.readline()) and line != b".\r\n":
                                message.extend(line)
                            reply = b"250 Delivered\r\n"
                        elif verb == b"QUIT":
                            self.wfile.write(b"221 Bye\r\n")
                            return
                        else: reply = b"250 OK\r\n"
                        self.wfile.write(reply)

            with socketserver.TCPServer(("127.0.0.1",0),Mailbox) as smtp:
                tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                tls.load_cert_chain(cert,key)
                smtp.socket = tls.wrap_socket(smtp.socket,server_side=True)
                worker = threading.Thread(target=smtp.serve_forever,daemon=True)
                worker.start()
                try:
                    config = Path(self.home.name)/"config/server.json"
                    config.write_text(json.dumps(dict(version=1,settings=dict(
                        TEFTER_PUBLIC_URL="https://workspace.test",TEFTER_SMTP_FROM="admin@workspace.test",
                        TEFTER_SMTP_CA_FILE=str(cert),TEFTER_SMTP_URL=f"smtps://127.0.0.1:{smtp.server_address[1]}"
                    ))))
                    self.start()
                    uid = self.call("POST","users",{"email":"new@example.test","password":self.password},self.admin)[1]["id"]
                    old = self.login("new@example.test")
                    self.call("POST","recovery/send",{"user":uid},self.admin,204)
                    token = re.search(rb"#recover=([a-f0-9]{64})",message).group(1).decode()
                    self.password = "another test password"
                    payload = {"token":token,"password":self.password}
                    self.call("POST","recovery/redeem",payload,extra={"X-Tefter-Login":"1"},expected=204)
                    self.call("POST","recovery/redeem",payload,extra={"X-Tefter-Login":"1"},expected=403)
                    self.call("GET","session",session=old,expected=401)
                    latest = self.login("new@example.test")
                    self.call("POST","password",{"current":self.password,"password":"third local password"},latest,204)
                    self.call("GET","session",session=latest,expected=401)
                finally:
                    smtp.shutdown()
                    worker.join()


if __name__ == "__main__":
    unittest.main()
