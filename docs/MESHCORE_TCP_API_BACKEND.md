# MeshCore TCP Companion API Backend

> Status: Experimental — not wired into `router.uc`. Phase 1 (smart accumulator + handshake + decoder) complete; Phase 2 live-hardware tests pending.

## Scope: TXT_MSG / GRP_TXT only

This backend exists for ONE job: surface cleartext MeshCore text messages into the Crow router. Adverts, telemetry, handshake responses, encrypted blobs, and vendor extensions are all dropped at the buffer layer without allocating payload memory. This keeps RAM exposure on OpenWrt routers minimal and the Part 97 regulatory surface tight.

## Why

Replace the abandoned KISS/TNC serial parser with a native TCP connection to a MeshCore radio's Companion Protocol on port 4403. This mirrors how the MeshMonitor dashboard talks to the radio — a structured binary command/response stream with asynchronous event frames.

**Critical distinction:**

| Port | Stack | Framing |
|------|-------|---------|
| Meshtastic 4403 | Protocol Buffers | `0x94 0xC3` + 2-byte length + protobuf payload (handled by `meshtastic_API.uc`) |
| MeshCore 4403 | Companion Protocol | `0x3E` magic + 1-byte cmd id + 2-byte BE length + raw binary payload (handled by `meshcore_tcp_api.uc`) |

They share a port number — nothing else.

## Architecture

```
            ┌──────────────────────────────────────────┐
            │            meshcore_tcp_api.uc            │
            │                                          │
TCP 4403 ──►│  recv()                                  │
            │   ├─ socket.recv(2048)                   │
            │   ├─ smartAccumulate()  ◄── Part 97 gate │
            │   │     │                                │
            │   │     ├─ oversize kill switch          │
            │   │     ├─ encrypted/blocked cmd drop    │
            │   │     ├─ unknown cmd drop              │
            │   │     └─ resync window cap             │
            │   └─ decodeTextFrame() (TXT_MSG/GRP_TXT) │
            │                                          │
            │  setup() → openTcp() + sendBootHandshake │
            │  reconnect timer (5s)                    │
            └──────────────────────────────────────────┘
                          │
                          ▼
                    router queue
                          │
                          ▼
            gatekeeper.filterInboundBridge() in router.uc
```

**No double-filtering:** `router.uc:queue()` runs the canonical `gatekeeper.filterInboundBridge()` pass on every queued `meshcore` message (callsign extraction, whitelist, `[SENDER via GATEWAY]` annotation). The backend caches a `strictHook` only for the Smart Accumulator's `early_drop_encrypted` decision — it does NOT call `filterInboundBridge` itself.

## Smart Accumulator (the "smart firewall buffer")

Crow runs on OpenWrt nodes with very little RAM. A naïve accumulator that trusts a TCP-supplied length field is vulnerable to memory exhaustion from a malicious or glitching radio. The Smart Accumulator pulls Strict Gatekeeper rules down into the buffer loop so we **fail closed before allocating payload bytes**.

Four gates fire BEFORE per-frame payload buffer allocation:

| Gate | Trigger | Action |
|------|---------|--------|
| **Oversize kill switch** | `payload_length > 256` | Drop header, arrange to discard the claimed payload bytes from the wire as they arrive. Bumps `early_drop_oversize`. |
| **Encrypted early-drop** | Strict Gatekeeper ON **and** cmd ∈ `{0x90, 0x91}` | Skip header + payload from buffer (or queue discard for incoming continuation). Bumps `early_drop_encrypted`. |
| **Unknown-cmd early-drop** | cmd ∉ `{TXT_MSG, GRP_TXT}` | Same as above. This catches HELLO_RESP, ADVERT, vendor extensions, and (with strict OFF) encrypted commands. Bumps `early_drop_unknown_cmd`. |
| **Malformed-text drop** | `plen < 9` or text-length byte > `plen - 9` | Drop the frame after full receive but before decoder allocation. Bumps `early_drop_malformed_text`. |

A fifth defensive cap (`RESYNC_BUFFER_CAP = 4096`) prevents the resync window from growing without bound when no magic byte ever appears.

`SMART_MAX_PAYLOAD` is tuned to MeshCore's real text MTU: ~150 byte text + 9 byte envelope = 159. The 256 cap is the smallest power-of-two that leaves headroom for variants while keeping a single frame well under one TCP MSS.

## Wire format

```
Companion frame:
  Off  Size  Field
  0    1     magic byte  (0x3E)
  1    1     command id
  2    2     payload length (big-endian)
  4    n     payload (n bytes)

TXT_MSG / GRP_TXT cleartext payload:
  Off  Size  Field
  0    4     sender node id   (uint32 little-endian)
  4    4     target node id   (uint32 little-endian; 0 = broadcast/group)
  8    1     text length (t)
  9    t     UTF-8 text bytes
```

## Handshake

On socket connect, send the MeshMonitor-equivalent boot sequence:

1. `[ 0x3E ][ CMD_HELLO=0x01           ][ len=0 ]`
2. `[ 0x3E ][ CMD_SUBSCRIBE_EVENTS=0x02 ][ len=0 ]`

The radio then asynchronously pushes `TXT_MSG` / `GRP_TXT` / `ADVERT` frames over the socket without polling.

## Decoded message shape

```json
{
    "transport":            "meshcore",
    "backend":              "tcp_api",
    "from":                 1234567890,
    "to":                   0,
    "rx_time":              <unix>,
    "hop_limit":            1,
    "originating_callsign": "<gateway-callsign>",
    "is_group":             true,
    "data": {
        "text_message": "hello mesh"
    }
}
```

All decoded text frames pass through `gatekeeper.filterInboundBridge(msg)` before being queued for the router.

## Test plan

### Group A — Buffer & State Machine (offline, run on every commit)

Run locally:

```sh
node tests/run_meshcore_tcp_api_tests.js
ucode -R -L tests/test_meshcore_tcp_api.uc        # on a node with ucode
```

| Test | What it proves |
|------|----------------|
| single frame | Header + payload parse, payload length preserved |
| fragmentation | Frame split across 3 reads is reassembled |
| oversize kill switch | `len=60000` is rejected without buffering |
| encrypted strict ON | `CMD_ENCRYPTED_DM` is dropped, stat bumped |
| encrypted strict OFF | Same frame falls to unknown-cmd gate (still dropped) |
| unknown cmd | Arbitrary cmd byte is dropped without buffering |
| pre-magic resync | Leading garbage is skipped to the next magic |
| back-to-back | Two frames in one read both emit |
| advert | `CMD_ADVERT` passes the accumulator |
| oversize drain | Buffer correctly skips a multi-read oversize blob and parses the next valid frame |

34/34 passing as of the tightened-contract commit.

### Group B — Handshake & Telemetry (live radio)

Requires a MeshCore radio (or `ser2net` proxy) reachable on TCP 4403.

1. **Connection** — Crow connects, sends HELLO + SUBSCRIBE_EVENTS, radio acks.
2. **Async stream** — RF text into the radio yields TXT_MSG / GRP_TXT pushes without poll.
3. **Reconnect recovery** — Radio reboot; Crow detects close, retries every 5s, re-handshakes on reconnect.

### Group C — Part 97 Compliance (live mesh)

1. **Cleartext injection** — RF text from a callsigned MeshCore node → Crow extracts, gatekeeper validates callsign, formatter appends `@MCGW>`, routes to AREDN.
2. **Unverified identity drop** — Same as above but sender callsign not in whitelist → message dropped after decode, before AREDN.

## Promotion criteria

This backend can replace the legacy UDP backend in production once it:

- passes all Group A fragmentation/memory-safety tests (✅ done);
- maintains a stable connection through a hardware reboot (Group B.3);
- prevents spoofed/encrypted packets from reaching the AREDN routing queue under Group C.2 conditions.

## Wiring up

Currently NOT imported by `router.uc`. To enable for bench testing, add to config:

```json
"meshcore_tcp_api": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 4403
}
```

…and import + call `setup()` / `recv()` in `router.uc`. Do not wire into production until promotion criteria are met.
