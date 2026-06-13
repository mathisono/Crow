# MeshCore TNC Backend Draft

This document tracks the new MeshCore KISS/TNC backend work. The existing `meshcore.uc` UDP multicast bridge backend is intentionally left untouched.

## Goal

Add a new backend that talks to MeshCore through the MeshCore KISS modem/TNC interface while preserving the current Crow-facing MeshCore message behavior.

The new backend must not read MeshCore traffic as a raw text string. It must unwrap KISS frames, accept KISS data frames, parse the raw MeshCore packet, resolve identity/key context, and only then hand a Crow message to routing/gatekeeper logic.

## New files

| File | Purpose |
| --- | --- |
| `meshcore_tnc.uc` | Public experimental TNC backend module. Exposes the same general backend shape: `setup`, `handle`, `recv`, `send`, `tick`, `shutdown`. |
| `meshcore_tnc_kiss.uc` | KISS frame reader/writer. Handles FEND/FESC framing and command-byte dispatch. |
| `meshcore_tnc_packet.uc` | Raw MeshCore packet parser/builder. Handles route type, payload type, path hash sizes, transport codes, ADVERT/direct/group/ACK envelope parsing. |
| `meshcore_tnc_crypto.uc` | Shared-key cache, direct text decrypt, group text decrypt, and outbound encryption helpers. |
| `meshcore_tnc_identity.uc` | ADVERT-based identity/location discovery, node DB enrichment, and callsign extraction. |

## Existing file intentionally not changed

```text
meshcore.uc
```

That file remains the current UDP/multicast bridge implementation. Use the new files only when testing the TNC path.

## Configuration draft

Initial test config can use a TCP KISS bridge such as `ser2net`/`socat`:

```json
{
  "meshcore_tnc": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 8001,
    "hashsize": 1,
    "kissport": 0
  }
}
```

Serial-device config is planned, but depends on the platform exposing an `openSerial()` helper:

```json
{
  "meshcore_tnc": {
    "enabled": true,
    "device": "/dev/ttyUSB0",
    "baud": 115200,
    "hashsize": 1,
    "kissport": 0
  }
}
```

If `platform.openSerial()` is unavailable, run a TCP KISS bridge and use `host`/`port` for testing.

## Receive path

```text
TNC byte stream
  -> meshcore_tnc_kiss.feed()
  -> KISS command byte
  -> command 0x00 Data: parse raw MeshCore packet
  -> command 0x06 SetHardware: ignore/log for now
  -> meshcore_tnc_packet.parse()
  -> ADVERT/direct/group/ACK handling
  -> meshcore_tnc_identity / meshcore_tnc_crypto
  -> Crow message object with transport="meshcore" and backend="tnc"
```

## Send path

```text
Crow message object
  -> meshcore_tnc.makeRawPackets()
  -> MeshCore raw packet builder
  -> meshcore_tnc_kiss.encodeData()
  -> TNC stream
```

## Gatekeeper placement

The gatekeeper must operate after KISS and MeshCore packet parsing, not on raw serial bytes. The new backend returns normal Crow message objects with additional context fields such as:

```json
{
  "transport": "meshcore",
  "backend": "tnc",
  "meshcore_payload_type": "TXT_MSG",
  "meshcore_route_type": "DIRECT",
  "meshcore_path_hash_size": 1,
  "meshcore_public_key": "...",
  "originating_callsign": "KJ6DZB"
}
```

This lets existing router/gatekeeper policy still see `transport: "meshcore"`, while debug logs can distinguish `backend: "tnc"` from the legacy bridge backend.

## Test checklist

1. Confirm `meshcore.uc` has no diff.
2. Load `meshcore_tnc_kiss.uc` and test empty frames are ignored.
3. Test KISS unescaping:
   - `0xDB 0xDC` becomes `0xC0`
   - `0xDB 0xDD` becomes `0xDB`
4. Confirm command low nibble is used:
   - `0x00` is Data
   - `0x06` is SetHardware/extension
5. Confirm SetHardware frames do not enter routing.
6. Confirm Data frames pass only raw MeshCore packet bytes to `meshcore_tnc_packet.parse()`.
7. Confirm packet parser handles 1-byte, 2-byte, and 3-byte path hash modes.
8. Confirm ADVERT updates identity/location data.
9. Confirm direct TXT_MSG decrypts into `data.text_message`.
10. Confirm group TXT decrypts but marks `meshcore_weak_identity = true`.
11. Confirm ACK handling clears pending ACKs.
12. Confirm outbound direct/group messages are KISS-wrapped as command 0x00 frames.
13. Confirm no Meshtastic/MeshCore cross-bridge behavior is introduced accidentally.
14. Only after the above, test a router import switch in a separate branch or image.

## Switch plan

Do not switch production Crow yet.

For a test image only, change the router import from:

```ucode
import * as meshcore from "meshcore";
```

to:

```ucode
import * as meshcore from "meshcore_tnc";
```

That provides a reversible single-line test switch while the legacy backend remains available.

Long term, once the TNC backend passes field tests, either:

1. promote `meshcore_tnc.uc` into `meshcore.uc`; or
2. add an explicit backend selector module.

The current commit does not do either, so legacy behavior remains untouched.
