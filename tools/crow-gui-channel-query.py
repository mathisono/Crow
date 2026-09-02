#!/usr/bin/env python3
"""Query a Crow channel using the same WebSocket protocol as ui/ui.js."""

import json
import sys
import time

from crow_websocket import WebSocket


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} HOST NAMEKEY [needle ...]", file=sys.stderr)
        return 2
    host, namekey = sys.argv[1:3]
    needles = sys.argv[3:]
    ws = WebSocket(host)
    try:
        ws.send_json({"cmd": "texts", "namekey": namekey})
        deadline = time.time() + 8
        while time.time() < deadline:
            try:
                opcode, payload = ws.recv_frame()
            except TimeoutError:
                continue
            if opcode != 1:
                continue
            event = json.loads(payload)
            if event.get("event") == "texts" and event.get("namekey") == namekey:
                texts = event.get("texts", [])
                print(json.dumps({
                    "host": host,
                    "namekey": namekey,
                    "count": len(texts),
                    "matches": [t for t in texts if any(n in str(t.get("text", "")) for n in needles)],
                    "last": texts[-5:],
                    "state": event.get("state"),
                }, separators=(",", ":")))
                return 0
        print(json.dumps({"host": host, "error": "texts timeout"}))
        return 1
    finally:
        ws.close()


if __name__ == "__main__":
    raise SystemExit(main())
