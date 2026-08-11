#!/usr/bin/env python3
"""Probe a directly attached MeshCore Companion radio over USB serial."""

from __future__ import annotations

import argparse
import struct
import sys
import time

try:
    import serial
except ImportError:
    print("pyserial is required; install it with: python3 -m pip install pyserial", file=sys.stderr)
    raise SystemExit(2)

PROFILES = {
    "crow_zeros": bytes.fromhex("010000000000000043726f77"),
    "meshcore_cli": bytes.fromhex("010320202020202043726f77"),
}


def frame(payload: bytes) -> bytes:
    return b"<" + struct.pack("<H", len(payload)) + payload


def has_self_info(data: bytes) -> bool:
    # Framed radio responses carry the response code after marker + length.
    if data.startswith(b">"):
        return len(data) >= 4 and data[3] == 0x05
    # Raw serial mode starts directly with the response code.
    return data.startswith(b"\x05")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", nargs="?", default="/dev/ttyACM0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--mode", choices=("framed", "raw", "auto"), default="auto")
    parser.add_argument("--profile", choices=tuple(PROFILES), default="meshcore_cli")
    args = parser.parse_args()

    attempts = [(args.mode, args.profile)] if args.mode != "auto" else [
        ("framed", "meshcore_cli"), ("framed", "crow_zeros"),
        ("raw", "meshcore_cli"), ("raw", "crow_zeros"),
    ]
    try:
        ser = serial.Serial(args.device, args.baud, timeout=0.1)
    except (OSError, serial.SerialException) as exc:
        print(f"Unable to open {args.device}: {exc}", file=sys.stderr)
        return 1

    with ser:
        for mode, profile in attempts:
            payload = PROFILES[profile]
            sent = frame(payload) if mode == "framed" else payload
            ser.reset_input_buffer()
            ser.write(sent)
            ser.flush()
            deadline = time.monotonic() + args.timeout
            received = bytearray()
            while time.monotonic() < deadline:
                received.extend(ser.read(4096))
                if has_self_info(received):
                    break
            print(f"mode={mode} profile={profile} sent={sent.hex()} received={bytes(received).hex()}")
            if has_self_info(received):
                print("RESP_SELF_INFO 0x05 found")
                return 0
    print("RESP_SELF_INFO 0x05 not found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
