# MeshCore TNC Backend Draft and Test Plan

Status: **draft implementation committed, not yet activated in production**.

This document preserves the current MeshCore TNC/KISS backend work while waiting on MeshCore hardware for live testing. The existing `meshcore.uc` UDP/multicast bridge backend is intentionally left untouched.

## Purpose

Crow already has a MeshCore backend in `meshcore.uc` that talks to the existing UDP/multicast bridge path. The new work adds a separate MeshCore TNC/KISS backend in new `.uc` files so it can be tested side-by-side without disturbing the known-good legacy backend.

The new backend must not read MeshCore traffic as raw text. It must:

```text
KISS/TNC byte stream
  -> KISS frame unwrap
  -> KISS command-byte check
  -> raw MeshCore packet parse
  -> originator/key/callsign/location discovery
  -> Crow message object
  -> Strict Gatekeeper / router decision
```

## Non-goals for the current draft

- Do not edit `meshcore.uc`.
- Do not switch the production router import yet.
- Do not remove the UDP/multicast bridge backend.
- Do not claim live hardware compatibility until tested with real MeshCore hardware.

## Current implementation status

| Phase | Status | Notes |
| --- | --- | --- |
| Phase 1: Shadow backend | **Implemented as draft** | New files exist beside `meshcore.uc`. Not wired into production router. |
| Phase 2: KISS frame layer | **Implemented as draft** | `meshcore_tnc_kiss.uc` unwraps/wraps KISS frames, handles FEND/FESC escaping, command low nibble, Data `0x00`, and SetHardware `0x06`. |
| Phase 3: MeshCore packet parser | **Implemented as draft** | `meshcore_tnc_packet.uc` parses route type, payload type, payload version, optional transport codes, path info, path bytes, and payload. Includes 1-, 2-, and 3-byte path hash support. |
| Phase 4: Replicate old backend behavior | **Partially implemented** | ADVERT, direct TXT, group TXT, ACK, outbound direct/group/adverts are drafted. PATH-with-embedded-ACK remains conservative and needs live validation. |
| Phase 5: Identity and gatekeeper context | **Partially implemented** | ADVERT identity/location discovery and public-key based direct-message resolution are drafted. Signed text public-key prefix verification is still marked incomplete. Group text is marked weak identity. |
| Phase 6: Switch strategy | **Documented only** | No production switch has been made. Test switch is a one-line router import change in a test branch/image only. |

## Commits preserving current progress

```text
f0dc8048b17e4e570fda24760d852a1a72c3c5d2  Add MeshCore TNC KISS frame codec
98962d6db0cf89dfcd9a7d313b6b4a9ccb3c4f1c  Add MeshCore TNC raw packet parser
362dc17883596628857fcb2bc341463e3cd486ec  Add MeshCore TNC identity helpers
62fdbf83c607ca29d019a41da8f51a1a576c408b  Add MeshCore TNC crypto helpers
bea56e4a7ac0f65085d9f94bc0fe134a9b143af7  Add MeshCore TNC backend module
9f4df439d327c2d3929acf2855ca9f8aec3e5bf5  Fix MeshCore TNC crypto import
cc97e62543b68d5eb2678ca04a0e73d14d92b474  Document MeshCore TNC backend draft
```

## New files

| File | Purpose |
| --- | --- |
| `meshcore_tnc.uc` | Experimental public TNC backend module. Exposes `setup`, `shutdown`, `handle`, `recv`, `send`, `tick`, and `process`. |
| `meshcore_tnc_kiss.uc` | KISS frame reader/writer. Handles `0xC0`, `0xDB`, `0xDC`, `0xDD`, command-byte dispatch, Data frames, and SetHardware frames. |
| `meshcore_tnc_packet.uc` | Raw MeshCore packet parser/builder. Handles route type, payload type, payload version, path hash sizes, transport codes, ADVERT/direct/group/ACK envelope parsing. |
| `meshcore_tnc_crypto.uc` | Shared-key cache, direct text decrypt, group text decrypt, and outbound encryption helpers. |
| `meshcore_tnc_identity.uc` | ADVERT-based identity/location discovery, node DB enrichment, and callsign extraction. |
| `docs/MESHCORE_TNC_BACKEND.md` | This status and test plan. |

## Existing file intentionally not changed

```text
meshcore.uc
```

That file remains the current UDP/multicast bridge implementation. Use the new files only when testing the TNC path.

## Phase 1: shadow backend test plan

Goal: prove the new files load and decode without changing production routing.

### Checks

```sh
git diff main -- meshcore.uc
```

Expected:

```text
no output
```

Confirm new files exist:

```sh
ls -1 meshcore_tnc*.uc docs/MESHCORE_TNC_BACKEND.md
```

Expected:

```text
meshcore_tnc.uc
meshcore_tnc_crypto.uc
meshcore_tnc_identity.uc
meshcore_tnc_kiss.uc
meshcore_tnc_packet.uc
docs/MESHCORE_TNC_BACKEND.md
```

### Acceptance criteria

- `meshcore.uc` is unchanged.
- New files can be reviewed independently.
- No router import has been switched on production.
- The old UDP bridge remains the active backend unless a test image explicitly imports `meshcore_tnc`.

## Phase 2: KISS frame layer test plan

Goal: verify that Crow unwraps KISS frames before trying to parse MeshCore packets.

### Expected KISS behavior

| Input behavior | Expected result |
| --- | --- |
| Empty frame between two `0xC0` bytes | Ignored. |
| `0xDB 0xDC` | Unescaped to `0xC0`. |
| `0xDB 0xDD` | Unescaped to `0xDB`. |
| Command low nibble `0x00` | Treat frame data as raw MeshCore packet. |
| Command low nibble `0x06` | Treat as SetHardware/telemetry; ignore or log, do not route. |
| Other command | Ignore for routing. |

### Manual byte tests

Create sample frames with the helper functions in `meshcore_tnc_kiss.uc`:

```ucode
import * as kiss from "meshcore_tnc_kiss";

let st = kiss.createState();
let frames = kiss.feed(st, kiss.encodeData("abc", 0));
```

Expected:

```text
frames[0].command == 0
frames[0].port == 0
frames[0].data == "abc"
```

Escaping test:

```ucode
let raw = chr(0xc0) + chr(0xdb);
let enc = kiss.encodeData(raw, 0);
let frames = kiss.feed(kiss.createState(), enc);
```

Expected:

```text
frames[0].data == raw
```

### Acceptance criteria

- KISS framing survives byte stuffing/un-stuffing.
- Data command frames produce only raw payload bytes for the packet parser.
- SetHardware `0x06` does not enter routing.
- Command matching uses `typebyte & 0x0f`, not the whole command byte.

## Phase 3: MeshCore packet parser test plan

Goal: validate raw MeshCore packet parsing without requiring a live radio.

### Packet fields to verify

```text
[header][transport_codes optional][path_length][path][payload]
```

| Parser output | Required behavior |
| --- | --- |
| `route_type` | Extract from header low 2 bits. |
| `payload_type` | Extract from header bits 2-5. |
| `payload_version` | Accept version 1 only for now. |
| `transport_codes` | Parse only for transport flood/direct route types. |
| `path_hash_size` | Compute from `pathinfo >> 6` plus 1. |
| `path_hash_count` | Compute from `pathinfo & 0x3f`. |
| `path` | Extract `hash_size * hash_count` bytes. |
| `payload` | Everything after path bytes. |

### Path hash tests

Test packets should be created or captured for each path size:

| Path mode | Path info high bits | Hash size | Expected |
| --- | --- | --- | --- |
| 1-byte path hash | `00` | 1 | Parser accepts and path byte count is `count * 1`. |
| 2-byte path hash | `01` | 2 | Parser accepts and path byte count is `count * 2`. |
| 3-byte path hash | `10` | 3 | Parser accepts and path byte count is `count * 3`. |
| Reserved | `11` | invalid | Parser rejects. |

### Acceptance criteria

- 1-byte, 2-byte, and 3-byte path hash modes parse correctly.
- Reserved path mode is rejected.
- Malformed short packets are rejected.
- Parser does not silently treat 3-byte paths as 1-byte paths.

## Phase 4: replicate old backend behavior test plan

Goal: verify that the new backend produces the same Crow-facing behavior as the old backend.

### Inbound packet types

| Packet type | Status | Test requirement |
| --- | --- | --- |
| `ADVERT` | Drafted | Must update `nodedb` with public key, name, role, and position. |
| `TXT_MSG` | Drafted | Must resolve shared key, HMAC-check, decrypt, and create `data.text_message`. |
| `GRP_TXT` | Drafted | Must decrypt channel text and create `data.text_message`; mark weak identity. |
| `ACK` | Drafted | Must clear pending ACK and create routing ACK message. |
| `PATH` | Conservative | Needs hardware/capture validation before full PATH-with-embedded-ACK support is enabled. |
| `REQ`, `RESPONSE`, `GRP_DATA`, `TRACE`, `MULTIPART`, `CONTROL`, `RAW_CUSTOM` | Not routed yet | Parser should not crash; routing can remain disabled until needed. |

### Crow message shape

TNC decoded messages should look like this:

```json
{
  "transport": "meshcore",
  "backend": "tnc",
  "from": 1234,
  "to": 4294967295,
  "hop_limit": 1,
  "namekey": "...",
  "data": {
    "text_message": "..."
  }
}
```

### Acceptance criteria

- `transport` remains `meshcore` so existing router/gatekeeper logic recognizes it.
- `backend` is `tnc` for debugging and side-by-side logging.
- ADVERT, direct text, group text, and ACK do not regress existing Crow message semantics.
- Group text includes weak-identity marker.

## Phase 5: identity and gatekeeper context test plan

Goal: make sure the gatekeeper sees useful identity before AREDN forwarding.

### Identity sources

| Source | Strength | Use |
| --- | --- | --- |
| ADVERT public key | Strongest available in this backend | Populate `nodedb`, map public key to node ID. |
| ADVERT name | Medium | Extract callsign-looking token where present. |
| Direct TXT source hash + HMAC/decrypt | Strong when public key resolved | Confirm sender is a known MeshCore public key. |
| Signed TXT public-key prefix | Not fully verified yet | Currently marked incomplete; must be improved. |
| Group TXT `name: message` | Weak | Use for display only; do not treat as cryptographic identity. |

### Gatekeeper preconditions

Before a TNC-derived message is forwarded into AREDN/Part 97 paths, verify:

- KISS frame is valid.
- KISS command is Data `0x00`.
- Raw MeshCore packet parses cleanly.
- Packet type is one of the expected routable types.
- Sender identity has been resolved if possible.
- Group messages are marked as weak identity.
- Strict Gatekeeper can still drop messages with insufficient identity.

### Acceptance criteria

- Direct text from known public key includes usable originator context.
- ADVERT packets update identity before later text packets rely on that identity.
- Group text is never upgraded to strong identity unless separately validated.
- Signed text verification gap is documented and not hidden.

## Phase 6: switch strategy and test plan

Goal: enable a reversible field test without disturbing the old backend.

### Current Phase 6 state

Phase 6 is **documented, not activated**.

No production import switch has been committed. The old backend remains active anywhere `router.uc` imports:

```ucode
import * as meshcore from "meshcore";
```

### Test switch only

For a temporary test image or test branch, change only this one line in `router.uc`:

```ucode
import * as meshcore from "meshcore";
```

to:

```ucode
import * as meshcore from "meshcore_tnc";
```

This gives a reversible test without renaming files or deleting the old backend.

### Rollback

Rollback is the inverse one-line change:

```ucode
import * as meshcore from "meshcore";
```

Then restart Crow.

### Acceptance criteria

- Test branch/image can use the TNC backend.
- Main branch can keep both implementations present.
- `meshcore.uc` remains available for immediate rollback.
- No production promotion happens until live tests pass.

## Hardware wait state

Current blocker: MeshCore hardware is not yet available. Expected delay: approximately 1-2 weeks.

While waiting for hardware:

1. Keep this test plan in the repo.
2. Review the new `.uc` files for syntax and import problems.
3. Build a small KISS frame replay harness if possible.
4. Collect/craft sample raw MeshCore ADVERT, TXT, GRP_TXT, and ACK packets.
5. Do not wire the new backend into production routing.

## Pre-hardware static review checklist

Run these from the repo root:

```sh
grep -R "meshcore_tnc" -n .
grep -R "import \* as meshcore from \"meshcore_tnc\"" -n . || true
grep -R "import \* as meshcore from \"meshcore\"" -n router.uc
```

Expected:

- New TNC files are found.
- No production router import points to `meshcore_tnc` unless on a deliberate test branch.
- `router.uc` still imports the old backend on production/main.

Check that the old file is present:

```sh
git ls-files meshcore.uc
```

Check new files:

```sh
git ls-files meshcore_tnc.uc meshcore_tnc_kiss.uc meshcore_tnc_packet.uc meshcore_tnc_crypto.uc meshcore_tnc_identity.uc
```

## Pre-hardware parser/replay tests

Create a small local harness later that can:

1. Import `meshcore_tnc_kiss`.
2. Encode a fake KISS Data frame.
3. Feed it back through `kiss.feed()`.
4. Confirm command/data round trip.
5. Import `meshcore_tnc_packet`.
6. Feed synthetic packets with 1-, 2-, and 3-byte path modes.
7. Confirm malformed path modes are rejected.

Minimum test vectors to create:

```text
KISS empty frame
KISS Data frame with normal bytes
KISS Data frame containing escaped 0xC0
KISS Data frame containing escaped 0xDB
KISS SetHardware frame
MeshCore packet: ADVERT
MeshCore packet: direct TXT_MSG
MeshCore packet: GRP_TXT
MeshCore packet: ACK
MeshCore packet: 3-byte path hash
```

## Hardware bring-up plan

When MeshCore hardware arrives:

### 1. Confirm TNC mode

- Put MeshCore device into KISS/TNC modem mode.
- Confirm serial settings: 115200 baud, 8N1, no flow control.
- Confirm host sees the device, likely `/dev/ttyUSB0`, `/dev/ttyACM0`, or similar.

### 2. Pick connection method

Preferred first test: TCP bridge to avoid uncertain platform serial APIs.

Example using `socat` or `ser2net` conceptually:

```text
/dev/ttyUSB0 115200 8N1 <-> 127.0.0.1:8001
```

Then configure:

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

### 3. Capture raw traffic

Run a capture on the TCP bridge or serial monitor.

Expected KISS markers:

```text
0xC0 ... 0xC0
```

Expected routing frames:

```text
KISS command low nibble 0x00
```

Expected telemetry/config frames:

```text
KISS command low nibble 0x06
```

### 4. Shadow decode first

Before changing router import, run a small harness or debug invocation that calls:

```ucode
meshcore_tnc.recv()
```

Expected:

- SetHardware frames ignored/logged.
- ADVERT frames update node identity.
- Text frames decode only after key discovery.
- No AREDN forwarding yet.

### 5. Test branch router switch

Only after shadow decode works, change `router.uc` in a test branch/image:

```ucode
import * as meshcore from "meshcore_tnc";
```

Restart Crow and watch logs.

### 6. Live message tests

| Test | Expected result |
| --- | --- |
| MeshCore ADVERT heard | `nodedb` learns MeshCore node public key, name, callsign-like token, and location if present. |
| MeshCore direct text to Crow/native node | Crow emits internal `transport=meshcore`, `backend=tnc`, `data.text_message`. |
| MeshCore group text | Crow emits `data.text_message`, `data.text_from`, and `meshcore_weak_identity=true`. |
| Crow native text to MeshCore group | TNC receives KISS Data frame wrapping a MeshCore GRP_TXT packet. |
| Crow direct text to known MeshCore node | TNC receives KISS Data frame wrapping TXT_MSG packet and pending ACK is stored. |
| ACK received | Pending ACK clears and routing ACK message is produced. |
| SetHardware telemetry | Logged/ignored, not forwarded. |
| Malformed KISS/packet | Dropped without crashing. |

## Promotion criteria

Do not replace old `meshcore.uc` until all are true:

- KISS decode tests pass.
- Packet parser tests pass.
- ADVERT identity discovery works on real hardware.
- Direct text decrypt/send works on real hardware.
- Group text decrypt/send works on real hardware.
- ACK behavior works or is explicitly scoped out.
- Strict Gatekeeper gets identity context before AREDN forwarding.
- Old backend rollback remains available.
- At least one clean reboot/restart test passes.

## Known gaps before promotion

| Gap | Impact | Next action |
| --- | --- | --- |
| Serial API uncertainty | `platform.openSerial()` may not exist on target. | Use TCP KISS bridge first; add platform serial helper later. |
| PATH-with-embedded-ACK conservative handling | Some ACK/path behavior may not fully match old backend yet. | Capture real PATH packets and implement after confirming format. |
| Signed text public-key prefix not fully verified | Strong identity claim is incomplete for signed text. | Verify prefix against resolved sender public key and fail closed if mismatch. |
| No router selector yet | Switching requires test branch import change. | After validation, add explicit backend selector or promote TNC backend. |
| No automated replay harness yet | Manual testing required. | Add replay tests once sample frames are available. |

## Notes for future developer/session

- The new backend intentionally adds functionality without touching old `meshcore.uc`.
- Keep `transport: "meshcore"` so existing router and gatekeeper logic continues to see MeshCore traffic.
- Use `backend: "tnc"` only as a debug/disambiguation field.
- Do not forward from raw KISS bytes. Always unwrap KISS and parse MeshCore packet first.
- Group text identity is weak by design; do not treat `name: message` as a cryptographic identity.
- Direct text identity depends on ADVERT/public-key discovery and HMAC/decryption success.
