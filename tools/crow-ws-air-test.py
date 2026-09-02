#!/usr/bin/env python3
"""Exercise Crow's WebSocket message path between two explicit endpoints."""

import argparse
import json
import select
import socket
import time

from crow_websocket import WebSocket


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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub", required=True, help="first Crow host or IP")
    parser.add_argument("--peer", required=True, help="second Crow host or IP")
    parser.add_argument("--sender", choices=("hub", "peer"), default="hub")
    parser.add_argument(
        "--token",
        default=f"CROW-AIR-TEST-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}",
        help="unique message text used to correlate received events",
    )
    args = parser.parse_args()

    token = args.token
    hub = WebSocket(args.hub)
    peer = WebSocket(args.peer)
    try:
        hub_channels = drain_initial(hub)
        peer_channels = drain_initial(peer)
        hub_names = {c.get("namekey"): c for c in hub_channels if c.get("meshcore")}
        peer_names = {c.get("namekey"): c for c in peer_channels if c.get("meshcore")}
        common = [namekey for namekey in hub_names if namekey in peer_names]
        print("common_channels", common, flush=True)
        if not common:
            raise RuntimeError("no common MeshCore channel")
        namekey = common[0]
        print("post", args.sender, namekey, token, flush=True)
        sender = peer if args.sender == "peer" else hub
        sender.send_json({"cmd": "post", "namekey": namekey, "text": token})
        sender.send_json({"cmd": "/cmd", "command": ["backends"]})

        seen = []
        deadline = time.time() + 25
        while time.time() < deadline:
            readable, _, _ = select.select([hub.sock, peer.sock], [], [], 1)
            for sock in readable:
                ws = hub if sock is hub.sock else peer
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
        peer.close()


if __name__ == "__main__":
    raise SystemExit(main())
