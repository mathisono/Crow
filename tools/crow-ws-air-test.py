#!/usr/bin/env python3
"""Exercise Crow's authenticated-by-origin WebSocket on two endpoints."""

import base64
import json
import os
import select
import socket
import struct
import sys
import time


class WebSocket:
    def __init__(self, host):
        self.host = host
        self.sock = socket.create_connection((host, 4404), timeout=5)
        self.sock.settimeout(5)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET / HTTP/1.1\r\nHost: {host}:4404\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            f"Origin: http://{host}:4404\r\n\r\n"
        ).encode()
        self.sock.sendall(request)
        header = self._read_until(b"\r\n\r\n")
        status = header.split(b"\r\n", 1)[0].decode("latin1")
        print(host, status, flush=True)
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


def drain_initial(ws, seconds=4):
    channels = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        ws.sock.settimeout(min(1, max(0.1, deadline - time.time())))
        try:
            opcode, payload = ws.recv_frame()
        except socket.timeout:
            continue
        if opcode == 8:
            break
        if opcode != 1:
            continue
        try:
            event = json.loads(payload)
        except (ValueError, UnicodeDecodeError):
            continue
        if event.get("event") == "channels":
            channels = event.get("channels", [])
            print(
                ws.host,
                "meshcore_channels",
                [(c.get("namekey"), c.get("label")) for c in channels if c.get("meshcore")],
                flush=True,
            )
    return channels


def main():
    token = sys.argv[1] if len(sys.argv) > 1 else "KJ6DZB@MCGW> RF-AIR-A2B-20260826T190600"
    sender_name = sys.argv[2] if len(sys.argv) > 2 else "hub5"
    hub = WebSocket("10.245.94.33")
    bb5 = WebSocket("10.52.8.205")
    try:
        hub_channels = drain_initial(hub)
        bb5_channels = drain_initial(bb5)
        hub_names = {c.get("namekey"): c for c in hub_channels if c.get("meshcore")}
        bb5_names = {c.get("namekey"): c for c in bb5_channels if c.get("meshcore")}
        common = [namekey for namekey in hub_names if namekey in bb5_names]
        print("common_channels", common, flush=True)
        if not common:
            raise RuntimeError("no common MeshCore channel")
        namekey = common[0]
        print("post", sender_name, namekey, token, flush=True)
        sender = bb5 if sender_name == "bb5" else hub
        sender.send_json({"cmd": "post", "namekey": namekey, "text": token})
        sender.send_json({"cmd": "/cmd", "command": ["backends"]})

        seen = []
        deadline = time.time() + 25
        while time.time() < deadline:
            readable, _, _ = select.select([hub.sock, bb5.sock], [], [], 1)
            for sock in readable:
                ws = hub if sock is hub.sock else bb5
                try:
                    opcode, payload = ws.recv_frame()
                except (EOFError, socket.timeout):
                    continue
                if opcode != 1:
                    continue
                try:
                    event = json.loads(payload)
                except (ValueError, UnicodeDecodeError):
                    continue
                serialized = json.dumps(event, separators=(",", ":"))
                if token in serialized or event.get("event") in ("rx", "reply", "text", "texts"):
                    print(ws.host, "EVENT", serialized[:1600], flush=True)
                if event.get("event") == "/reply":
                    print(ws.host, "BACKENDS", serialized[:5000], flush=True)
                if token in serialized:
                    seen.append(ws.host)
        print("TOKEN_SEEN_ON", sorted(set(seen)), flush=True)
        return 0 if seen else 2
    finally:
        hub.close()
        bb5.close()


if __name__ == "__main__":
    raise SystemExit(main())
