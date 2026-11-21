"""Real RFC 6455 clients; no mock hub or third-party Python dependencies."""
from identity import Workspace
import base64
import hashlib
import json
import os
import socket
import struct
import uuid


class SocketClient:
    def __init__(self,port,path,headers):
        self.socket=socket.create_connection(('127.0.0.1',port),timeout=4)
        self.buffer=b''
        key=base64.b64encode(os.urandom(16)).decode()
        request=(f'GET /api/v1/{path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
                 f'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n'+
                 ''.join(k+': '+v+'\r\n' for k,v in headers.items())+'\r\n')
        self.socket.sendall(request.encode())
        while b'\r\n\r\n' not in self.buffer: self.buffer+=self.socket.recv(65536)
        head,self.buffer=self.buffer.split(b'\r\n\r\n',1)
        self.status=int(head.split()[1])
        if self.status==101:
            expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
            assert expected in head

    def read(self,n):
        while len(self.buffer)<n:
            chunk=self.socket.recv(65536)
            if not chunk: raise EOFError()
            self.buffer+=chunk
        data,self.buffer=self.buffer[:n],self.buffer[n:]
        return data

    def receive(self):
        fragments=b''
        while True:
            first,length=self.read(2)
            opcode=first&15
            length=length&127
            if length==126: length=struct.unpack('!H',self.read(2))[0]
            if length==127: length=struct.unpack('!Q',self.read(8))[0]
            data=self.read(length)
            if opcode==8: return None
            if opcode==9:
                self.send_frame(data,10); continue
            fragments+=data
            if first&128: return json.loads(fragments)

    def send_frame(self,data,opcode=1):
        mask=os.urandom(4)
        length=len(data)
        header=bytes([128|opcode,128|length]) if length<126 else bytes([128|opcode,128|126])+struct.pack('!H',length)
        self.socket.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(data)))

    def send(self,data): self.send_frame(json.dumps(data).encode())
    def close(self): self.socket.close()


class Live(Workspace):
    def connect(self,path,session,origin=True):
        headers=dict(session)
        if origin: headers['Origin']=f'http://127.0.0.1:{self.port}'
        client=SocketClient(self.port,path,headers)
        self.addCleanup(client.close)
        return client

    def test_live_reconnect_revocation(self):
        a=self.admin
        user=self.call('POST','users',{'email':'live@test.org','password':self.password},a)[1]['id']
        b=self.login('live@test.org')
        org=self.call('POST','organizations',{'name':'Live'},a)[1]['id']
        space=self.call('POST',f'organizations/{org}/spaces',{'name':'Live'},a)[1]['id']
        base=f'spaces/{space}/'
        channel=self.call('GET',base+'channels',session=a)[1]['channels'][0]['id']
        path=base+f'channels/{channel}/live'
        self.assertNotEqual(self.connect(path,b).status,101)
        self.assertNotEqual(self.connect(path,a,False).status,101)
        evil=dict(a,Origin='https://evil.test')
        self.assertNotEqual(self.connect(path,evil,False).status,101)
        self.call('PUT',f'organizations/{org}/members',{'user':user},a,204)
        self.call('PUT',base+'members',{'user':user},a,204)
        one,two=self.connect(path,a),self.connect(path,b)
        self.assertEqual((one.status,two.status),(101,101))
        payload={'body':'Live **hello**','nonce':str(uuid.uuid4()),'csrf':a['X-CSRF-Token']}
        one.send(payload)
        m1,m2=one.receive(),two.receive()
        self.assertEqual(m1,m2)
        self.assertEqual(m1['body'],payload['body'])
        one.close()
        route=base+f'channels/{channel}/messages'
        second=self.call('POST',route,{'body':'while disconnected','nonce':str(uuid.uuid4())},a)[1]
        self.assertEqual(two.receive(),second)
        resumed=self.connect(path+'?after='+str(m1['sequence']),a)
        self.assertEqual(resumed.receive(),second)
        invalid=self.connect(path+'?after='+str(second['sequence']),a)
        invalid.send({'body':'bad csrf','nonce':str(uuid.uuid4()),'csrf':'invalid'})
        self.assertIsNone(invalid.receive())
        self.call('DELETE',base+'members',{'user':user},a,204)
        # An existing subscribed client closes when its grant is removed.
        self.assertIsNone(two.receive())
        self.call('POST',route,{'body':'denied','nonce':str(uuid.uuid4())},b,404)
        self.assertNotEqual(self.connect(path,b).status,101)
        agent=self.call('POST','agents',{'name':'Live agent'},a)[1]
        bearer={'Authorization':'Bearer '+agent['token']}
        self.assertNotEqual(self.connect(path,bearer,False).status,101)
        self.call('PUT',base+'agents',{'id':agent['id']},a,204)
        agent_socket=self.connect(path+'?after='+str(second['sequence']),bearer,False)
        self.assertEqual(agent_socket.status,101)
        agent_socket.send({'body':'agent event','nonce':str(uuid.uuid4())})
        event=agent_socket.receive()
        self.assertEqual((event['author'],event['authorKind']),(agent['id'],'agent'))
        self.call('DELETE',base+'agents',{'id':agent['id']},a,204)
        self.assertIsNone(agent_socket.receive())
        # Drain the same event from the human subscription before logout.
        self.assertEqual(resumed.receive(),event)
        self.call('POST','logout',session=a,expected=204)
        self.assertIsNone(resumed.receive())
