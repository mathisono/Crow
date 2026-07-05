#!/usr/bin/env python3

import socket

HOST = "10.245.94.47"
PORT = 4403


def read_exact(sock, size):
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            return b""
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(sock):
    header = read_exact(sock, 3)
    if len(header) < 3:
        return b""
    marker = header[0]
    length = header[1] | (header[2] << 8)
    payload = read_exact(sock, length)
    if len(payload) < length:
        return b""
    return bytes([marker]) + header[1:3] + payload


def build_handshake_frame():
    payload = b"\x01" + b"\x00" * 7 + b"Crow"
    return b"\x3c" + len(payload).to_bytes(2, "little") + payload


def test_meshcore_protocol():
    print(f"[*] Connecting to {HOST}:{PORT}...")
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.settimeout(8.0)
        s.connect((HOST, PORT))
        print("[+] TCP Connection established with TCP_NODELAY.")

        frame = build_handshake_frame()
        print(f"[*] Sending full CMD_APP_START frame ({len(frame)} bytes): {frame.hex()}")
        s.sendall(frame)

        print("[*] Waiting for PACKET_SELF_INFO (0x05)...")
        frame = read_frame(s)
        if not frame:
            print("[-] Connection closed immediately by peer. Handshake failed.")
            return

        marker = frame[0]
        plen = frame[1] | (frame[2] << 8)
        payload = frame[3:]
        print(f"[+] Received frame marker=0x{marker:02x} payload_len={plen}")
        if marker != 0x3e:
            print(f"[-] Unexpected radio-to-client marker: 0x{marker:02x}")
            return

        if payload and payload[0] == 0x05:
            print("[+] Success: Decoded PACKET_SELF_INFO (0x05)")
            if len(payload) > 33:
                name_bytes = payload[33:]
                node_name = name_bytes.lstrip(b"\x00").decode("utf-8", errors="ignore").strip()
                print(f"[+] meshcore_tcp_api: parseSelfInfo: device name = {node_name}")
        else:
            got = payload[0] if payload else None
            print(f"[-] Unexpected initial frame code: 0x{got:02x}" if got is not None else "[-] Empty payload")
            return

    except Exception as e:
        print(f"[-] Protocol state verification error: {e}")
    finally:
        if s is not None:
            s.close()
        print("[*] Socket closed.")


if __name__ == "__main__":
    test_meshcore_protocol()
