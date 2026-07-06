#!/usr/bin/env python3
"""
MeshCore Companion TCP validation helper for Crow.

This script validates the Companion API framing expected by meshcore_tcp_api.uc.
It sends a full framed CMD_APP_START command, not the raw 12-byte payload.

Expected outbound bytes:

    3c0c00010000000000000043726f77

Frame layout:

    '<' + uint16_le(length=12) + CMD_APP_START + seven zero bytes + 'Crow'

The first useful radio response is usually RESP_SELF_INFO / PACKET_SELF_INFO
(code 0x05) in a radio-to-client frame beginning with '>' (0x3e).
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

FRAME_TO_RADIO = 0x3C       # '<'
FRAME_FROM_RADIO = 0x3E     # '>'
CMD_APP_START = 0x01
CMD_SYNC_NEXT_MESSAGE = 0x0A
RESP_SELF_INFO = 0x05
PUSH_CODE_MSG_WAITING = 0x83
RESP_NO_MORE_MESSAGES = 0x0A

EXPECTED_APP_START_HEX = "3c0c00010000000000000043726f77"


class Frame:
    def __init__(self, marker: int, payload: bytes):
        self.marker = marker
        self.payload = payload

    @property
    def code(self) -> int | None:
        return self.payload[0] if self.payload else None


def build_command(cmd: int, payload: bytes = b"") -> bytes:
    frame_payload = bytes([cmd & 0xFF]) + payload
    return bytes([FRAME_TO_RADIO]) + struct.pack("<H", len(frame_payload)) + frame_payload


def build_app_start(app_name: str = "Crow") -> bytes:
    payload = b"\x00" * 7 + app_name.encode("utf-8")
    return build_command(CMD_APP_START, payload)


def recv_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("connection closed while reading")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def recv_frame(sock: socket.socket) -> Frame:
    header = recv_exact(sock, 3)
    marker = header[0]
    length = struct.unpack("<H", header[1:3])[0]
    payload = recv_exact(sock, length) if length else b""
    return Frame(marker=marker, payload=payload)


def format_code(code: int | None) -> str:
    return "none" if code is None else f"0x{code:02x}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate MeshCore Companion TCP framing")
    parser.add_argument("host", help="MeshCore Companion TCP host/IP")
    parser.add_argument("--port", type=int, default=4403, help="TCP port, default 4403")
    parser.add_argument("--timeout", type=float, default=10.0, help="socket timeout seconds")
    parser.add_argument("--drain-on-83", action="store_true", help="send CMD_SYNC_NEXT_MESSAGE if 0x83 is seen")
    parser.add_argument("--max-frames", type=int, default=10, help="maximum response frames to read")
    args = parser.parse_args()

    app_start = build_app_start()
    app_start_hex = app_start.hex()

    print(f"[*] Connecting to {args.host}:{args.port}...")
    print(f"[*] Framed CMD_APP_START ({len(app_start)} bytes): {app_start_hex}")
    if app_start_hex != EXPECTED_APP_START_HEX:
        print(f"[-] Internal error: expected {EXPECTED_APP_START_HEX}", file=sys.stderr)
        return 2

    try:
        with socket.create_connection((args.host, args.port), timeout=args.timeout) as sock:
            sock.settimeout(args.timeout)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print("[+] TCP connection established with TCP_NODELAY.")
            sock.sendall(app_start)
            print("[*] Waiting for radio-to-client frames...")

            saw_self_info = False
            saw_msg_waiting = False
            saw_no_more = False

            for i in range(args.max_frames):
                frame = recv_frame(sock)
                code = frame.code
                print(
                    f"[+] frame {i + 1}: marker=0x{frame.marker:02x} "
                    f"len={len(frame.payload)} code={format_code(code)} payload={frame.payload.hex()}"
                )

                if frame.marker != FRAME_FROM_RADIO:
                    print("[!] Unexpected marker; expected radio-to-client 0x3e")
                    continue

                if code == RESP_SELF_INFO:
                    saw_self_info = True
                    print("[+] Got RESP_SELF_INFO / PACKET_SELF_INFO (0x05).")
                    # Keep reading briefly in case a message-waiting push follows.
                    if not args.drain_on_83:
                        break

                if code == PUSH_CODE_MSG_WAITING:
                    saw_msg_waiting = True
                    print("[+] Got PUSH_CODE_MSG_WAITING (0x83).")
                    if args.drain_on_83:
                        sync_frame = build_command(CMD_SYNC_NEXT_MESSAGE)
                        print(f"[*] Sending CMD_SYNC_NEXT_MESSAGE: {sync_frame.hex()}")
                        sock.sendall(sync_frame)

                if code == RESP_NO_MORE_MESSAGES:
                    saw_no_more = True
                    print("[+] Got RESP_NO_MORE_MESSAGES (0x0a).")
                    if args.drain_on_83:
                        break

            print("[*] Summary:")
            print(f"    self_info={saw_self_info}")
            print(f"    message_waiting={saw_msg_waiting}")
            print(f"    no_more_messages={saw_no_more}")
            return 0 if saw_self_info else 1

    except (OSError, ConnectionError, TimeoutError) as exc:
        print(f"[-] Validation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
