# Crow Backend Compatibility and Compliance Plan

> Last updated: 2026-06-18

## Current Direction

- **meshtastic.uc** — production UDP/multicast Meshtastic backend. Unchanged.
- **meshtastic_API.uc** — experimental TCP Port-API backend. Isolated; not wired into production router.
- **meshcore.uc** — existing MeshCore UDP backend. Unchanged.
- **MeshCore TNC/KISS** — removed from the repo. All `meshcore_tnc*.uc` files and related docs/tests deleted.
- **Strict Gatekeeper** — the safety boundary for all bridged LoRa text entering AREDN/native routing.
- Backend code must normalize messages into Crow's existing message shape (see `message.uc`).

---

## File-by-File Status

### meshtastic.uc — ✅ Compliant

Production UDP/multicast backend. Drops encrypted packets when Strict Gatekeeper is enabled. Must remain unchanged.

### meshtasticprotobufs.uc — ✅ Fixed

Registers only standard Meshtastic packet/data protos into the `meshtastic` module. `fromradio`/`toradio` Port-API envelope protos removed — they are self-registered inside `meshtastic_API.uc` into its own private proto table.

### meshtastic_API.uc — ✅ Compliant

TCP Port-API backend. Self-registers its own `fromradio`, `toradio`, `packet`, and `data` protos into a private `protos` object (not the `meshtastic` module). Has gatekeeper enforcement: drops encrypted packets when Strict Gatekeeper is enabled. Not wired into `router.uc`.

### router.uc — ✅ Compliant

Imports only `meshtastic` and `meshcore`. Runs `gatekeeper.filterInboundBridge()` on all meshtastic/meshcore inbound traffic.

### gatekeeper.uc — ✅ Compliant

Enforces: encrypted packet drop, non-text packet drop, US callsign validation, whitelist filtering, gateway callsign annotation (`[SENDER via GATEWAY]`).

### channel.uc — ✅ Compliant

Maintains Meshtastic presets, MeshCore hashes, AREDN-only channels.

### meshcore.uc — ✅ Compliant

Existing MeshCore UDP/multicast backend. Unchanged.

### meshtastic_tagged.uc — ✅ Compliant

Wraps `meshtastic.uc` (UDP) with outbound gateway tagging via `lora_outbound_text`. Does not switch between UDP and TCP API backends.

### lora_outbound_text.uc — ✅ Fixed

Formats outbound LoRa text as `CALLSIGN@TAG> message`. Transport normalization:
- `meshtastic` / `meshtastic_api` / `meshtastic_API` → `meshtastic` (tag: `MTGW`)
- `meshcore` → `meshcore` (tag: `MCGW`)

### message.uc — ✅ Compliant

Creates Crow-native messages with correct shape. Stable baseline.

### STRICT_GATEKEEPER.md — ✅ Updated

Renamed Raven → Crow. Added "Backend coverage" section.

---

## Removed (2026-06-18)

All MeshCore TNC/KISS code and documentation deleted:

| Deleted file | Description |
|------|--------|
| `meshcore_tnc.uc` | MeshCore KISS/TNC backend |
| `meshcore_tnc_tagged.uc` | Tagged text wrapper for TNC backend |
| `meshcore_tnc_kiss.uc` | KISS frame codec |
| `meshcore_tnc_packet.uc` | Raw packet parser/builder |
| `meshcore_tnc_crypto.uc` | Shared-key and payload decode helpers |
| `meshcore_tnc_identity.uc` | Identity/location discovery helpers |
| `docs/MESHCORE_TNC_BACKEND.md` | TNC backend design doc |

Also cleaned: `lora_outbound_text.uc` (removed `meshcore_tnc` alias), test files (removed TNC test cases), `tests/README.md`, `STRICT_GATEKEEPER.md`, `docs/CROW_MIGRATION_PLAN.md`.

---

## Compliance Checks (run from repo root)

```sh
# No meshcore_tnc files or references
find . -iname '*meshcore*tnc*' | grep -v .git
grep -Rni 'meshcore_tnc' --include='*.uc' --include='*.md' --include='*.json' .

# No fromradio/toradio in meshtasticprotobufs (comments OK)
grep -ni 'fromradio\|toradio' meshtasticprotobufs.uc | grep -v '^[0-9]*://'

# Gatekeeper enforcement in meshtastic backends
grep -n 'gatekeeper' meshtastic.uc
grep -n 'gatekeeper' meshtastic_API.uc

# Meshtastic import scope
grep -Rni 'import \* as meshtastic' --include='*.uc' .
```

## Expected Message Shape (meshtastic_API.uc)

When `meshtastic_API.uc` emits messages, they must match:

```json
{
  "from": "<node-id>",
  "to": "<target-id>",
  "namekey": "<channel-namekey>",
  "id": "<unique-id>",
  "rx_time": "<unix-timestamp>",
  "priority": "<when-available>",
  "hop_limit": "<int>",
  "transport": "meshtastic",
  "backend": "tcp-port-api",
  "originating_callsign": "<gateway-callsign>",
  "data": {
    "text_message": "<message-text>"
  }
}
```

## Gatekeeper Test Cases

- Encrypted packet → dropped
- Non-text packet → dropped
- Invalid callsign (no US format) → dropped
- Valid callsign, not on whitelist → dropped
- Valid callsign, on whitelist → passed, annotated
- Gateway annotation format: `[SENDER via GATEWAY] message`
