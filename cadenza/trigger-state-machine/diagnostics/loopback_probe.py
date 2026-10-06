#!/usr/bin/env python3
"""Local-only DNS + HTTP/WebSocket acceptance fixture. Never persists payloads.
Usage: python3 loopback_probe.py /absolute/test/binary /private/output.json
Only synthetic audio and dummy credentials. No system DNS/config/Keychain changes.
"""
import base64, gzip, hashlib, json, os, socket, socketserver, struct, subprocess, sys, threading, time
from collections import Counter
lock = threading.Lock()
events = []
def record(kind, **fields):
    with lock: events.append(dict(kind=kind, at=time.monotonic(), **fields))
def exact(sock, n):
    out = b''
    while len(out) < n:
        part = sock.recv(n-len(out))
        if not part: raise EOFError()
        out += part
    return out
class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        record('tcp_accept')
        s = self.request; s.settimeout(5)
        try:
            raw = b''
            while b'\r\n\r\n' not in raw:
                raw += exact(s, 1)
                if len(raw)>16384: return
            lines = raw.decode().split('\r\n'); path = lines[0].split()[1].strip('/')
            headers = {k.lower():v for line in lines[1:] if ': ' in line for k,v in [line.split(': ',1)]}
            record('connection', scenario=path)
            if 'sec-websocket-key' not in headers:
                body = exact(s, int(headers.get('content-length','0')))
                # Never store the request body (including synthetic PCM).
                is_audio = b'"speech"' in body
                record('http', scenario=path, audio=is_audio)
                if path.endswith('aliyun'):
                    response={'Token':{'Id':'local-token','ExpireTime':int(time.time())+3600}}
                elif is_audio: response={'err_no':0,'result':['']}
                else: response={'access_token':'local-token','expires_in':3600}
                data=json.dumps(response).encode()
                s.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data)
                return
            accept=base64.b64encode(hashlib.sha1((headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
            s.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
            if path.endswith('tencent'):
                reply=json.dumps({'code':0,'message':'success','voice_id':headers.get('x-probe-voice-id')}).encode()
                s.sendall(bytes([129,len(reply)])+reply)
            while True:
                a,b=exact(s,2); opcode=a & 15; size=b & 127
                if size==126: size=struct.unpack('!H',exact(s,2))[0]
                elif size==127: size=struct.unpack('!Q',exact(s,8))[0]
                if size>1048576: return
                mask=exact(s,4) if b & 128 else None
                payload=exact(s,size)
                if mask: payload=bytes(v ^ mask[i%4] for i,v in enumerate(payload))
                if opcode==8: return
                audio=False
                if opcode==1:
                    try:
                        obj=json.loads(payload); audio=bool(obj.get('data',{}).get('audio'))
                        if path.endswith('tencent'): audio=False
                        if path.endswith('aliyun'):
                            reply=json.dumps({'header':{'name':'TranscriptionStarted','status':20000000,'task_id':obj.get('header',{}).get('task_id')}}).encode()
                            s.sendall(bytes([129,len(reply)])+reply)
                    except (ValueError,AttributeError): pass
                elif opcode==2: audio=path.endswith(('tencent','aliyun')) or (path.endswith('volcengine') and len(payload)>8 and payload[1] >> 4 == 2 and bool(gzip.decompress(payload[8:])))
                if audio:
                    down=float(headers.get('x-probe-down',time.monotonic()))
                    record('audio', scenario=path, received_after_down_ms=(time.monotonic()-down)*1000)
        except (OSError,EOFError,ValueError): pass
class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        query,s=self.request
        if len(query)<12: return
        at=12; labels=[]
        while at<len(query) and query[at]:
            n=query[at];at+=1;labels.append(query[at:at+n].decode('ascii'));at+=n
        host='.'.join(labels); record('dns', host=host)
        # Exact DNS answer to the received question: A 127.0.0.1, TTL 0.
        reply=query[:2]+b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00'+query[12:]+b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x00\x00\x04\x7f\x00\x00\x01'
        s.sendto(reply,self.client_address)
class Server(socketserver.ThreadingTCPServer):
    daemon_threads=True
with Server(('127.0.0.1',0),TCP) as tcp, socketserver.ThreadingUDPServer(('127.0.0.1',0),UDP) as dns:
    for server in [tcp,dns]: threading.Thread(target=server.serve_forever,daemon=True).start()
    env=dict(os.environ,TRIGGER_LOCAL_PORT=str(tcp.server_address[1]),TRIGGER_DNS_PORT=str(dns.server_address[1]))
    runs=[]
    commands=[['--diagnose-trigger-network']]+[['--diagnose-trigger-latency',mode] for _ in range(3) for mode in ['legacy','gated']]
    for args in commands:
        start=time.monotonic()
        p=subprocess.run([sys.argv[1],*args],env=env,capture_output=True,text=True,timeout=30)
        with lock: sample=[e for e in events if e['at']>=start]
        runs.append(dict(args=args,exit=p.returncode,stdout=p.stdout.strip(),events=sample))
        print(json.dumps(dict(args=args,exit=p.returncode,stdout=p.stdout.strip(),counts=dict(Counter(e['kind'] for e in sample)))),flush=True)
    result={'scope':'fixture UDP DNS packets and loopback TCP requests only; not whole-machine DNS observation','runs':runs}
    out=sys.argv[2];fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as f: json.dump(result,f,indent=2)
    tcp.shutdown();dns.shutdown()
    if any(r['exit'] for r in runs): sys.exit(1)
    network=runs[0]['events']
    positives=[e['at'] for e in network if e['kind']=='connection']
    # DNS must also be empty throughout negative scenarios; compare the first positive DNS.
    marks=[]
    for line in runs[0]['stdout'].splitlines():
        if 'finished-cycles-' in line: marks.append(float(line.split('uptime=')[1]))
    if len(marks)!=4 or any(e['at']<=max(marks) for e in network): sys.exit(2)
    seen={e.get('scenario') for e in network if e['kind']=='connection'}
    audio_seen={e.get('scenario') for e in network if e['kind']=='audio' or (e['kind']=='http' and e.get('audio'))}
    if not all('positive-'+p in audio_seen for p in ['iflytek','volcengine','tencent','aliyun','baidu']): sys.exit(4)
    if not all('positive-'+p in seen for p in ['iflytek','volcengine','tencent','aliyun','baidu']): sys.exit(3)
