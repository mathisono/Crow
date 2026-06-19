# MeshCore TNC Backend Draft and Test Plan

Status: **deferred while Meshtastic TCP Port-API backend is the active focus**.

This document preserves the MeshCore TNC/KISS backend design notes and test plan. The existing `meshcore.uc` UDP/multicast bridge backend should remain functional and should not be rewritten during the Meshtastic direct-backend pass.

## Current project decision

Crow's immediate backend work is Meshtastic, not MeshCore:

- Implement Meshtastic as a direct TCP Port-API backend.
- Do not implement Meshtastic serial support.
- Do not mix MeshCore parsing into Meshtastic code.
- Do not rewrite MeshCore in the Meshtastic pass.
- Keep current MeshCore behavior working.
- Return to MeshCore after the Meshtastic direct TCP backend is stable.

See `docs/MESHTASTIC_TCP_PORT_API_BACKEND.md` for the current active backend plan.

## Future MeshCore direction

When MeshCore work resumes, the target is to expose the same Crow-facing backend shape as the Meshtastic direct backend:

```text
setup(config)
tick()
recv()
send(msg)
shutdown()
```

The router should remain protocol-neutral. MeshCore-specific KISS/TNC parsing should stay inside MeshCore-specific files.

Target boundary:

```text
MeshCore packet/frame
  -> MeshCore-specific parser
  -> normalized Crow message
  -> strict gatekeeper / router decision
```

Outbound target boundary:

```text
Crow router message
  -> MeshCore backend send function
  -> MeshCore-specific packet/frame encoding
```

## Purpose

Crow already has a MeshCore backend in `meshcore.uc` that talks to the existing UDP/multicast bridge path. The draft TNC/KISS design adds a separate MeshCore path in new `.uc` files so it can be tested side-by-side without disturbing the known-good legacy backend.

The new backend must not read MeshCore traffic as raw text. It must follow a real decode chain:

```text
KISS/TNC byte stream
  -> KISS frame unwrap
  -> KISS command-byte check
  -> raw MeshCore packet parse
  -> originator/key/callsign/location discovery
  -> Crow message object
  -> Strict Gatekeeper / router decision
```

## Non-goals while Meshtastic is active

- Do not edit `meshcore.uc` except for a narrowly required bug fix.
- Do not switch the production router import to a TNC backend.
- Do not remove the UDP/multicast bridge backend.
- Do not claim live hardware compatibility until tested with real MeshCore hardware.
- Do not spend this pass normalizing MeshCore unless it is required to keep current behavior from breaking.

## Draft implementation status

| Phase | Status | Notes |
| --- | --- | --- |
| Phase 1: Shadow backend | **Drafted / deferred** | New-file strategy remains preferred for later testing. Not wired into production router. |
| Phase 2: KISS frame layer | **Drafted / deferred** | KISS unwrap/wrap work should handle FEND/FESC escaping, command low nibble, Data `0x00`, and SetHardware `0x06`. |
| Phase 3: MeshCore packet parser | **Drafted / deferred** | Parser should handle route type, payload type, payload version, optional transport codes, path info, path bytes, and payload. |
| Phase 4: Replicate old backend behavior | **Deferred** | ADVERT, direct TXT, group TXT, ACK, outbound direct/group/adverts need live validation. |
| Phase 5: Identity and gatekeeper context | **Deferred** | ADVERT identity/location discovery, public-key resolution, and callsign extraction need hardware-backed validation. |
| Phase 6: Switch strategy | **Deferred** | No production switch should happen until Meshtastic direct backend work is stable and MeshCore hardware testing is available. |

## Existing file intentionally preserved

```text
meshcore.uc
```

That file remains the current MeshCore implementation. Keep it available for rollback and production continuity.

## Future test plan

### Phase 1: shadow backend

Goal: prove any new MeshCore TNC files load and decode without changing production routing.

Checks:

```sh
git diff main -- meshcore.uc
ls -1 meshcore_tnc*.uc docs/MESHCORE_TNC_BACKEND.md
```

Expected:

- `meshcore.uc` is unchanged or only minimally changed for a documented bug fix.
- New files can be reviewed independently.
- No router import has been switched on production.
- The old UDP bridge remains active unless a test image explicitly opts into the TNC path.

### Phase 2: KISS frame layer

Goal: verify that Crow unwraps KISS frames before trying to parse MeshCore packets.

Expected KISS behavior:

| Input behavior | Expected result |
| --- | --- |
| Empty frame between two `0xC0` bytes | Ignored. |
| `0xDB 0xDC` | Unescaped to `0xC0`. |
| `0xDB 0xDD` | Unescaped to `0xDB`. |
| Command low nibble `0x00` | Treat frame data as raw MeshCore packet. |
| Command low nibble `0x06` | Treat as SetHardware/telemetry; ignore or log, do not route. |
| Other command | Ignore for routing. |

Acceptance criteria:

- KISS framing survives byte stuffing/un-stuffing.
- Data command frames produce only raw payload bytes for the packet parser.
- SetHardware `0x06` does not enter routing.
- Command matching uses `typebyte & 0x0f`, not the whole command byte.

### Phase 3: MeshCore packet parser

Goal: validate raw MeshCore packet parsing without requiring a live radio.

Packet fields to verify:

```text
[header][transport_codes optional][path_length][path][payload]
```

| Parser output | Required behavior |
| --- | --- |
| `route_type` | Extract from header low 2 bits. |
| `payload_type` | Extract from header bits 2-5. |
| `payload_version` | Accept version 1 only until newer versions are validated. |
| `transport_codes` | Parse only for transport flood/direct route types. |
| `path_hash_size` | Compute from `pathinfo >> 6` plus 1. |
| `path_hash_count` | Compute from `pathinfo & 0x3f`. |
| `path` | Extract `hash_size * hash_count` bytes. |
| `payload` | Everything after path bytes. |

Acceptance criteria:

- 1-byte, 2-byte, and 3-byte path hash modes parse correctly.
- Reserved path mode is rejected.
- Malformed short packets are rejected.
- Parser does not silently treat 3-byte paths as 1-byte paths.

### Phase 4: Crow message shape

TNC decoded messages should normalize toward this shape:

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

Acceptance criteria:

- `transport` remains `meshcore` so existing router/gatekeeper logic recognizes it.
- `backend` is `tnc` for debugging and side-by-side logging.
- ADVERT, direct text, group text, and ACK do not regress existing Crow message semantics.
- Group text includes a weak-identity marker unless cryptographic identity is separately validated.

### Phase 5: identity and gatekeeper context

Before a MeshCore-derived message is forwarded into AREDN/Part 97 paths, verify:

- KISS frame is valid.
- KISS command is Data `0x00`.
- Raw MeshCore packet parses cleanly.
- Packet type is one of the expected routable types.
- Sender identity has been resolved if possible.
- Group messages are marked as weak identity.
- Strict Gatekeeper can still drop messages with insufficient identity.

## Later switch strategy

No production switch should be made now.

When testing resumes, use a reversible test image or test branch only. If a future test branch uses a different MeshCore module, make the import change isolated and easy to revert. Do not rename or delete the current `meshcore.uc` backend until the new path has live hardware validation.

## Hardware wait state

Current blocker: MeshCore hardware/live captures are required before any production activation. Until then, this document is a planning and preservation note, not an activation request.
