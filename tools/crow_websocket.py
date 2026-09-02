"""Minimal Crow WebSocket client shared by live-node development tools."""

import base64
import json
import os
import socket
import struct


class WebSocket:
    def __init__(self, host, port=4404, timeout=5):
        self.host = host
        self.port = port
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            f"Origin: http://{host}:{port}\r\n\r\n"
        ).encode()
        self.sock.sendall(request)
        header = self._read_until(b"\r\n\r\n")
        if b"101" not in header.split(b"\r\n", 1)[0]:
            raise RuntimeError(header.decode("latin1", "replace"))

    def _read_until(self, marker):
        data = b""
        while marker not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise EOFError("WebSocket closed during handshake")
            data += chunk
        return data

    def _read_exact(self, size):
        data = b""
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            if not chunk:
                raise EOFError("WebSocket closed")
            data += chunk
        return data

    def recv_frame(self):
        header = self._read_exact(2)
        opcode = header[0] & 0x0F
        size = header[1] & 0x7F
        masked = header[1] & 0x80
        if size == 126:
            size = struct.unpack(">H", self._read_exact(2))[0]
        elif size == 127:
            size = struct.unpack(">Q", self._read_exact(8))[0]
        mask = self._read_exact(4) if masked else None
        payload = bytearray(self._read_exact(size))
        if mask:
            for i in range(size):
                payload[i] ^= mask[i & 3]
        return opcode, bytes(payload)

    def send_json(self, value):
        payload = json.dumps(value, separators=(",", ":")).encode()
        mask = os.urandom(4)
        if len(payload) < 126:
            header = bytes((0x81, 0x80 | len(payload)))
        elif len(payload) < 65536:
            header = bytes((0x81, 0xFE)) + struct.pack(">H", len(payload))
        else:
            header = bytes((0x81, 0xFF)) + struct.pack(">Q", len(payload))
        masked = bytes(byte ^ mask[i & 3] for i, byte in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def close(self):
        self.sock.close()
