# MeshCore TCP / Serial-WiFi API Backend

> Status: Implemented. Stock outer framing, bounded message-waiting sync, channel discovery, direct/channel receive, and direct/channel transmit are shared by the TCP and USB serial transports. Live hardware validation remains transport/device dependent.

## Scope

This backend exists to surface cleartext MeshCore text messages into the Crow
router through the MeshCore TCP / Serial-WiFi API path. The same Companion
implementation is exposed as `meshcore_serial_api.uc` for directly attached
USB serial radios; see `MESHCORE_USB_SERIAL_COMPANION_BACKEND.md`.

It is not the production MeshCore path yet. The original UDP backend,
`meshcore.uc`, remains available while TCP API send/receive behavior is
validated on live hardware.

## Critical distinction: MeshCore 4403 is not Meshtastic 4403

| Port | Stack | Framing |
|------|-------|---------|
| Meshtastic 4403 | Protocol Buffers | Meshtastic TCP Port-API framing handled by `meshtastic_API.uc` |
| MeshCore 4403 | Serial/Wi-Fi API | `>` / `<` marker, 2-byte little-endian length, frame payload handled by `meshcore_tcp_api.uc` |

They may share a port number. They do not share a protocol.

## Stock MeshCore outer framing

Radio to client:

```text
[ '>' ][ length LSB ][ length MSB ][ frame payload ]
```

Client to radio:

```text
[ '<' ][ length LSB ][ length MSB ][ frame payload ]
```

The frame payload begins with the MeshCore command, response, or push code.

## Receive flow

MeshCore does not push the whole message as the initial event.

The corrected receive flow is:

```text
0x83 = PUSH_CODE_MSG_WAITING
client sends CMD_SYNC_NEXT_MESSAGE = 0x0A
radio returns queued message response
client decodes response code 0x07 / 0x08 / 0x10 / 0x11
```

Handled codes:

| Code | Meaning | Current Crow behavior |
|---:|---|---|
| `0x83` | message waiting push/tickle | sends `0x0A` sync-next-message |
| `0x0A` | command: sync/fetch next queued message | sent by `sendCommand()` |
| `0x07` | older direct-message receive response | decoded as direct text |
| `0x08` | older channel/group-message receive response | decoded as group text with slot metadata |
| `0x10` | newer v3 direct-message receive response | decoded through the current direct-text envelope |
| `0x11` | newer v3 channel/group-message receive response | decoded through the current group-text envelope |
| `0x12` | channel info response | cached for discovery/control |

If v3 payloads add fields before text, split the v3 decode logic in `decodeTextFrame()`.

## Architecture

```text
            ┌──────────────────────────────────────────┐
            │            meshcore_tcp_api.uc            │
            │                                          │
TCP 4403 ──►│  recv()                                  │
            │   ├─ socket.recv(2048)                   │
            │   ├─ smartAccumulate()                   │
            │   │     ├─ '>' frame marker              │
            │   │     ├─ uint16 little-endian length   │
            │   │     ├─ oversize kill switch          │
            │   │     ├─ encrypted/blocked drop        │
            │   │     ├─ unknown-code drop             │
            │   │     ├─ 0x83 -> send 0x0A             │
            │   │     └─ response cache for 0x12       │
            │   └─ decodeTextFrame()                   │
            │                                          │
            │  sendCommand()                           │
            │   └─ '<' + uint16le(length) + payload    │
            │                                          │
            │  reconnect timer (5s)                    │
            └──────────────────────────────────────────┘
                          │
                          ▼
                    router queue
                          │
                          ▼
            gatekeeper.filterInboundBridge() in router.uc
```

USB serial uses the same diagram and parser. Its transport operations are
`fs.read()`/`fs.write()` on the pollable serial device rather than
`socket.recv()`/`socket.send()`.

No double-filtering: `router.uc:queue()` runs the canonical `gatekeeper.filterInboundBridge()` pass on every queued `meshcore` message. The backend only uses a cached strict-mode probe for early encrypted-frame dropping.

## Discovery

`meshcore_tcp_discovery.uc` now sends channel discovery requests through `meshcore_tcp_api.sendCommand()`.

Discovery request:

```text
CMD_GET_CHANNEL = 0x1F
payload = slot index 0-7
```

Response:

```text
RESP_CODE_CHANNEL_INFO = 0x12
50-byte payload total:
  byte 0      0x12
  byte 1      channel index, 0-7
  bytes 2-33  32-byte channel name, null-padded UTF-8
  bytes 34-49 16-byte secret
```

The TCP backend caches `0x12` responses. Discovery drains cached responses using `takeResponse(0x12)` and maps discovered slots to channels.

Because the socket is non-blocking, discovery is asynchronous: one sync may send requests, and a later sync may parse responses that arrived afterward.

## Smart Accumulator

The Smart Accumulator protects low-RAM OpenWrt nodes by rejecting unsafe frames as early as possible.

| Gate | Trigger | Action |
|------|---------|--------|
| oversize | frame payload length > 256 | discard frame / skip remaining bytes |
| encrypted early-drop | Strict Gatekeeper ON and code in `{0x90, 0x91}` | drop before routing |
| unknown code | code is not one Crow handles | drop |
| malformed text | direct/group payload does not match expected envelope | drop |
| resync cap | no `>` marker within bounded buffer | discard garbage |

## Decoded message shape

Direct message example:

```json
{
  "transport": "meshcore",
  "backend": "tcp_api",
  "from": 1234567890,
  "to": 0,
  "hop_limit": 1,
  "data": {
    "text_message": "hello mesh"
  },
  "metadata": {
    "is_group_message": false,
    "local_direct": true,
    "direct_identity_verified": false,
    "identity_strength": "strong",
    "text_type": 0
  }
}
```

Legacy direct frames carry a destination id. When self-info has provided the
connected radio public-key prefix, Crow verifies that destination and sets
`direct_identity_verified = true`; verified mismatches are dropped by
`router.uc`. Modern Companion direct frames in this parser do not expose a
destination id, so they keep the queue-origin `local_direct` fallback until
hardware validation identifies a destination-bearing format or command.

Group message example:

```json
{
  "transport": "meshcore",
  "backend": "tcp_api",
  "from": 1234567890,
  "group_slot": 3,
  "hop_limit": 1,
  "data": {
    "text_message": "hello group"
  },
  "metadata": {
    "is_group_message": true,
    "group_slot": 3,
    "identity_strength": "weak",
    "symmetric_key": true,
    "requires_slot_lookup": true
  }
}
```

## Test plan

Run locally:

```sh
node tests/run_meshcore_tcp_api_tests.js
ucode -R -L tests/test_meshcore_tcp_api.uc        # on a node with ucode
```

The tests cover:

- `>` radio-to-client frame parsing
- `<` client-to-radio command construction
- little-endian length handling
- fragmentation across reads
- oversize frame rejection
- strict-mode encrypted early drop
- unknown-code drop
- message waiting `0x83`
- sync-next-message command `0x0A`
- direct response decode `0x07`
- group response decode `0x08`
- v3 response decode acceptance `0x10` / `0x11`
- channel-info response cache `0x12`
- resync after garbage
- back-to-back frames

## Remaining work

Before using this as the production MeshCore path:

1. Test against real MeshCore TCP/Wi-Fi or USB serial frames.
2. Add captured-frame regression tests.
3. Confirm whether v3 `0x10` / `0x11` payloads match the current envelope.
4. Implement outbound text send for the TCP API backend.
5. Confirm discovery timing with real hardware.

## Wiring up

Enable for bench testing with:

```json
"meshcore": {
  "enabled": false
},
"meshcore_tcp_api": {
  "enabled": true,
  "host": "127.0.0.1",
  "port": 4403
}
```

The selector in `meshcore_backend.uc` can choose this backend when `meshcore_tcp_api.enabled=true` and the UDP backend is disabled, or when `meshcore.backend` / `meshcore.transport` explicitly requests `api`, `tcp-api`, or `companion-api`.
