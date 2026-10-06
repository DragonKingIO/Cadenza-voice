"""Minimal client for the local voice API (version 1). Python 3.8+, standard library only.

    from voice_client import Client
    api = Client()                      # reads the token file, talks to 127.0.0.1:17420
    session = api.start()               # the Mac microphone starts recording
    ...                                 # speak
    api.stop(session["id"])
    print(api.wait(session["id"])["text"])
"""
import base64
import http.client
import json
import os
import socket
import struct

TOKEN_FILE = os.path.expanduser("~/Library/Application Support/Yansui/local-api-token")


class ApiError(Exception):
    def __init__(self, status, code, message):
        super().__init__("%s (%s): %s" % (code, status, message))
        self.status, self.code, self.message = status, code, message


def read_token(path=TOKEN_FILE):
    with open(path, "r") as handle:
        return handle.read().strip()


class Client:
    def __init__(self, port=17420, token=None, host="127.0.0.1"):
        self.host, self.port = host, port
        self.token = token or read_token()

    def _request(self, method, path, body=None, timeout=40):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        try:
            payload = json.dumps(body).encode() if body is not None else None
            headers = {"Authorization": "Bearer " + self.token}
            if payload is not None:
                headers["Content-Type"] = "application/json"
            connection.request(method, path, body=payload, headers=headers)
            response = connection.getresponse()
            data = json.loads(response.read() or b"{}")
        finally:
            connection.close()
        if response.status >= 400:
            error = data.get("error", {})
            raise ApiError(response.status, error.get("code", "error"), error.get("message", ""))
        return data

    def capabilities(self):
        return self._request("GET", "/v1/capabilities")

    def start(self, max_seconds=None):
        return self._request("POST", "/v1/sessions", {"max_seconds": max_seconds} if max_seconds else None)

    def stop(self, session_id):
        return self._request("POST", "/v1/sessions/%s/stop" % session_id)

    def cancel(self, session_id):
        return self._request("POST", "/v1/sessions/%s/cancel" % session_id)

    def get(self, session_id, wait=0):
        return self._request("GET", "/v1/sessions/%s?wait=%d" % (session_id, wait))

    def wait(self, session_id, timeout=30):
        """Long-poll until the session is completed, cancelled or failed."""
        import time
        deadline = time.time() + timeout
        while True:
            info = self.get(session_id, wait=min(25, max(1, int(deadline - time.time()))))
            if info["state"] not in ("recording", "processing") or time.time() >= deadline:
                return info


class Events:
    """WebSocket connection. A session started with `start()` here is owned by the connection:
    if the connection closes (cable pulled, script crashed) the recording is cancelled."""

    def __init__(self, port=17420, token=None, host="127.0.0.1"):
        self.sock = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        request = ("GET /v1/ws HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer %s\r\n\r\n"
                   % (host, port, key, token or read_token()))
        self.sock.sendall(request.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1024)
            if not chunk:
                raise ApiError(0, "closed", "connection closed during handshake")
            head += chunk
        status = int(head.split(b" ", 2)[1])
        if status != 101:
            raise ApiError(status, "handshake_failed", head.split(b"\r\n")[0].decode())
        self.buffer = head.split(b"\r\n\r\n", 1)[1]

    def send(self, message):
        data = json.dumps(message).encode()
        mask = os.urandom(4)
        header = bytearray([0x81])
        if len(data) < 126:
            header.append(0x80 | len(data))
        else:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(data))
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(bytes(header) + mask + masked)

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ApiError(0, "closed", "connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def recv(self, timeout=None):
        """Next event as a dict (None for non-text frames)."""
        self.sock.settimeout(timeout)
        first, second = self._read(2)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read(8))[0]
        payload = self._read(length)
        opcode = first & 0x0F
        if opcode == 8:
            raise ApiError(0, "closed", "server closed the connection")
        return json.loads(payload) if opcode == 1 else None

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class AudioSession:
    """Submit audio from your own source (hardware bridge) and get text back. Needs the `audio` permission.

        with AudioSession(token=device_token) as session:
            session.start(max_seconds=30)
            for chunk in pcm_chunks:          # raw s16le mono 16 kHz
                session.send_audio(chunk)
            print(session.finish()["text"])
    """

    def __init__(self, port=17420, token=None, host="127.0.0.1"):
        self.sock = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        request = ("GET /v1/audio HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer %s\r\n\r\n"
                   % (host, port, key, token or read_token()))
        self.sock.sendall(request.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1024)
            if not chunk:
                raise ApiError(0, "closed", "connection closed during handshake")
            head += chunk
        status = int(head.split(b" ", 2)[1])
        if status != 101:
            body = head.split(b"\r\n\r\n", 1)[1]
            try:
                error = json.loads(body).get("error", {})
            except ValueError:
                error = {}
            raise ApiError(status, error.get("code", "handshake_failed"), error.get("message", head.split(b"\r\n")[0].decode()))
        self.buffer = head.split(b"\r\n\r\n", 1)[1]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _send_frame(self, opcode, payload):
        mask = os.urandom(4)
        header = bytearray([0x80 | opcode])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        else:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
        self.sock.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ApiError(0, "closed", "connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _recv(self, timeout=30):
        self.sock.settimeout(timeout)
        first, second = self._read(2)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read(8))[0]
        payload = self._read(length)
        if first & 0x0F == 8:
            raise ApiError(0, "closed", "server closed the connection")
        return json.loads(payload) if first & 0x0F == 1 else None

    def start(self, max_seconds=60, deliver="none"):
        self._send_frame(1, json.dumps({"op": "start", "sample_rate": 16000, "channels": 1, "format": "pcm_s16le",
                                        "max_seconds": max_seconds, "deliver": deliver}).encode())
        event = self._recv()
        if event.get("type") == "error":
            error = event["error"]
            raise ApiError(0, error["code"], error["message"])
        return event

    def send_audio(self, pcm):
        for offset in range(0, len(pcm), 32000):
            self._send_frame(2, pcm[offset:offset + 32000])

    def finish(self, timeout=60):
        """Ends the audio and waits for the final text. Raises ApiError when recognition fails."""
        self._send_frame(1, b'{"op":"end"}')
        while True:
            event = self._recv(timeout)
            if event is None or event.get("type") == "partial":
                continue
            if event["type"] == "error":
                raise ApiError(0, event["error"]["code"], event["error"]["message"])
            return event

    def cancel(self):
        self._send_frame(1, b'{"op":"cancel"}')

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
