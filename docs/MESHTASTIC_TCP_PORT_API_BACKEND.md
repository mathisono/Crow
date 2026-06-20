# Meshtastic TCP Port-API Backend Plan

Status: **active experimental backend plan**.

Crow keeps the existing Meshtastic UDP/multicast backend and the experimental Meshtastic TCP Port-API backend separate:

```text
meshtastic.uc       # existing UDP/multicast backend; keep unchanged
meshtastic_API.uc   # experimental TCP Port-API backend
```

The current `meshtastic_API.uc` focus is **read-only channel auto-discovery and periodic read-only refresh**. Two-way channel writes are deliberately out of scope for this pass.

## Current direction

- Do not modify `meshtastic.uc`; it must remain the existing UDP/multicast backend.
- Do not wire `meshtastic_API.uc` into `router.uc` by default.
- Do not touch MeshCore for this task.
- Do not use Python, npm, protoc, generated protobuf files, or external protobuf libraries.
- Use pure ucode buffer parsing and the existing Crow coding style.
- Use Crow's existing `timers.setInterval()` / `timers.tick()` pattern.
- Do not implement serial support.
- Do not require MQTT.
- Do not persist discovered channel data in this pass.

## Current capability

`meshtastic_API.uc` has experimental TCP Port-API plumbing and read-only discovery code:

- maintains a TCP socket to a Meshtastic node on port `4403`;
- handles the `0x94 0xc3` Meshtastic TCP Port-API frame header;
- extracts payload lengths;
- decodes `FromRadio.packet`;
- sends outbound text using `ToRadio.packet`;
- sends `ToRadio.want_config_id` when discovery is enabled;
- scans `FromRadio.channel` for channel index, name, and PSK;
- records discovered channels in a runtime-only map;
- keeps the original `meshtastic.uc` backend unchanged.

## Experimental config

```json
{
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403,
    "channel_discovery": true,
    "channel_sync": "read_only",
    "channel_refresh_seconds": 600
  }
}
```

Defaults:

- `channel_discovery`: `false`
- `channel_sync`: `"off"`
- `channel_refresh_seconds`: `600`

`channel_sync` must remain `off` or `read_only`. Bidirectional radio configuration writes are future work.

## Correct Meshtastic protobuf tags

| Object | Field | Wire type | Tag |
| --- | ---: | --- | --- |
| `FromRadio.packet` | 2 | length-delimited | `0x12` |
| `FromRadio.config_complete_id` | 7 | varint | `0x38` |
| `FromRadio.channel` | 10 | length-delimited | `0x52` |
| `ToRadio.packet` | 1 | length-delimited | `0x0A` |
| `ToRadio.want_config_id` | 3 | varint | `0x18` |
| `Channel.index` | 1 | varint | `0x08` |
| `Channel.settings` | 2 | length-delimited | `0x12` |
| `ChannelSettings.name` | 3 | length-delimited string | `0x1A` |
| `ChannelSettings.psk` | 4 | length-delimited bytes | `0x22` |

Rejected assumptions:

- Do not treat `FromRadio.channel` as field 3.
- Do not treat `ToRadio.packet` as field 2.
- Do not register TCP API-only config envelopes into the old UDP backend.

## Backend boundary

Inbound path:

```text
TCP Port-API stream
  -> 0x94 0xc3 frame parser
  -> FromRadio envelope parser
  -> packet OR channel/config handler
  -> normalized Crow message OR read-only channel discovery map
```

Outbound text path:

```text
Crow router message
  -> Meshtastic API send function
  -> ToRadio.packet field 1
  -> 0x94 0xc3 TCP Port-API frame
```

Read-only discovery path:

```text
ToRadio.want_config_id field 3
  -> Meshtastic config dump
  -> FromRadio.channel field 10
  -> channel index/name/PSK extraction
  -> runtime discoveredChannels map
```

The router remains protocol-neutral.

## Implemented behavior in this pass

### Envelope registration

`meshtastic_API.uc` registers the corrected envelope fields:

- `fromradio.packet` field 2;
- `fromradio.config_complete_id` field 7;
- `fromradio.channel` field 10;
- `toradio.packet` field 1;
- `toradio.want_config_id` field 3.

### Lightweight TLV parser

The backend includes local parser helpers for protobuf wire types needed by discovery:

```ucode
readVarint(buf, off)
readLenDelimited(buf, off)
skipField(buf, off, wire_type)
extractChannels(buf)
```

Parser rules:

- check bounds before every read;
- reject varints longer than 10 bytes;
- reject length-delimited fields whose length exceeds remaining buffer;
- return partial/null on malformed data;
- log bounded parser detail with `DEBUG2`, not byte-by-byte spam.

### Runtime discovery map

The backend stores discovered channels in a runtime-only map:

```ucode
let discoveredChannels = {};
```

Rules:

- ignore empty names;
- ignore empty PSKs;
- never log raw PSKs;
- log index, name, added/updated state, and short PSK fingerprint only;
- do not write permanent config files;
- do not mutate `config.channels`;
- do not overwrite operator-configured Crow channels.

### Config request

When `channel_discovery` is enabled, the backend sends `ToRadio.want_config_id`:

- after TCP connect;
- after reconnect;
- on periodic refresh.

The request is framed as:

```text
0x94 0xc3 + 2-byte big-endian protobuf length + (0x18 + varint request_id)
```

### Refresh

The backend uses Crow timers:

```ucode
timers.setInterval("meshtastic_API.channel_refresh", refresh_seconds)
```

The `tick()` path calls `requestConfig("refresh")` only when discovery is enabled and the TCP socket is connected.

## Not implemented yet

Do not implement these until read-only discovery is hardware-validated:

- persistent Crow channel sync;
- radio write-back sync;
- `encodeChannelProto(index, name, psk)`;
- admin/channel-set request;
- ACK/config-complete verification for writes;
- automatic radio reboot/reconfigure handling;
- operator UI for committing discovered channels to config.

## Test plan

### 1. Static separation checks

Run from the Crow repo root:

```sh
# router must still use the production UDP Meshtastic backend by default
grep -n 'import \* as meshtastic from "meshtastic"' router.uc
! grep -n 'import \* as meshtastic from "meshtastic_API"' router.uc

# meshtastic.uc should remain UDP/multicast oriented
grep -n '224.0.0.69\|SOCK_DGRAM\|IP_ADD_MEMBERSHIP' meshtastic.uc

# experimental API backend should contain discovery-specific code
grep -n 'channel_discovery\|want_config_id\|discoveredChannels\|extractChannels\|FROMRADIO_CHANNEL_TAG' meshtastic_API.uc

# TCP API-only FromRadio/ToRadio config envelopes should not be in the UDP proto file
! grep -n 'fromradio\|toradio\|want_config_id\|config_complete_id' meshtasticprotobufs.uc
```

Expected:

- router import remains `meshtastic`, not `meshtastic_API`;
- `meshtastic.uc` still shows UDP/multicast code;
- discovery symbols exist only in `meshtastic_API.uc`;
- TCP API-only config envelopes are not registered into `meshtasticprotobufs.uc`.

### 2. Syntax checks

```sh
ucode -R -L . meshtastic_API.uc
ucode -R -L . meshtastic.uc
ucode -R -L . router.uc
```

Expected:

- no syntax errors;
- no missing imports introduced by `meshtastic_API.uc`.

### 3. TLV parser unit-style checks

Add test hooks or a small test file if practical. Validate:

- `readVarint()` decodes one-byte varints;
- `readVarint()` decodes multi-byte varints;
- overlong varints are rejected after 10 bytes;
- truncated varints return null/partial safely;
- `readLenDelimited()` rejects length larger than remaining buffer;
- `skipField()` handles wire type 0 and wire type 2;
- unsupported wire types are skipped/rejected safely without throwing.

Synthetic `FromRadio.channel` fixture should include:

```text
0x52 <len>
  0x08 <index-varint>
  0x12 <settings-len>
    0x1A <name-len> <name>
    0x22 <psk-len> <psk-bytes>
```

Expected decoded record:

```json
{
  "index": 0,
  "name": "LongFast",
  "psk_b64": "...",
  "namekey": "LongFast ..."
}
```

### 4. Want-config frame generation test

Validate `buildWantConfigId(id)` generates:

```text
94 c3 00 <len> 18 <varint-id>
```

For a one-byte request ID such as `1`, expected payload after the TCP frame header is:

```text
18 01
```

Expected:

- frame begins with `0x94 0xc3`;
- length equals protobuf payload length;
- protobuf payload begins with tag `0x18`;
- request ID is encoded as varint.

### 5. Packet RX/TX regression checks

Confirm existing experimental packet behavior still works:

- inbound `FromRadio.packet` still returns a normalized Crow message;
- packet messages still use `transport: "meshtastic"`;
- packet messages still use `backend: "tcp-port-api"`;
- encrypted/unsupported packet drop behavior is unchanged;
- outbound text uses `ToRadio.packet` field 1.

### 6. Discovery disabled behavior

Config:

```json
{
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403
  }
}
```

Expected:

- backend may connect;
- no `want_config_id` is sent;
- no channel refresh timer sends config requests;
- normal packet RX/TX behavior remains available.

### 7. Discovery enabled behavior

Config:

```json
{
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403,
    "channel_discovery": true,
    "channel_sync": "read_only",
    "channel_refresh_seconds": 600
  }
}
```

Expected:

- `want_config_id` is sent after connect;
- `want_config_id` is sent after reconnect;
- periodic refresh sends another `want_config_id`;
- `FromRadio.channel` frames update runtime `discoveredChannels`;
- logs show index/name/add-or-update;
- logs do not print raw PSKs;
- no persistent config files are modified.

### 8. Malformed input tests

Feed malformed frames if a test hook exists:

- truncated `0x52` channel length;
- length-delimited field longer than remaining buffer;
- overlong varint;
- unknown field with supported wire type;
- unknown field with unsupported wire type;
- channel with empty name;
- channel with empty PSK.

Expected:

- no throw/crash;
- parser returns null/partial safely;
- unknown fields do not prevent packet RX;
- empty channel records are ignored;
- logs remain bounded.

### 9. Real-node hardware validation

1. Enable Meshtastic node Wi-Fi/LAN.
2. Confirm Crow host can reach TCP port `4403`:

   ```sh
   nc -vz 192.168.4.1 4403
   ```

3. Manually wire `meshtastic_API.uc` only for the test.
4. Enable:

   ```json
   "channel_discovery": true,
   "channel_sync": "read_only"
   ```

5. Start Crow and watch logs.
6. Confirm TCP connect.
7. Confirm `want_config_id` is sent.
8. Confirm `FromRadio.channel` records arrive.
9. Confirm channel names/indexes are logged.
10. Confirm raw PSKs are not logged.
11. Confirm inbound text still routes.
12. Confirm outbound text still sends.
13. Reboot or power-cycle the Meshtastic node.
14. Confirm reconnect occurs.
15. Confirm reconnect triggers another config request.
16. Confirm no persistent Crow config file or override file changed.

### 10. Release/merge acceptance

Before treating discovery as usable:

- static checks pass;
- syntax checks pass;
- parser tests pass or equivalent manual TLV fixture test is documented;
- real-node connect/config-dump works;
- raw PSKs are not logged;
- `meshtastic.uc` remains unchanged as UDP/multicast;
- `router.uc` is not switched by default;
- docs and wiki say this is experimental read-only discovery, not full bidirectional sync.

## Manual OpenClaw test prompt

```text
In mathisono/Crow, test the committed Meshtastic API read-only channel discovery code.

Do not modify meshtastic.uc.
Do not switch router.uc to meshtastic_API.uc except temporarily for the explicit hardware test, and revert that wiring before final commit unless asked otherwise.
Do not touch MeshCore.
Do not implement bidirectional channel writes.

Run static separation checks, ucode syntax checks, TLV fixture tests if practical, want_config_id frame generation checks, packet RX/TX regression checks, discovery-disabled behavior, discovery-enabled behavior, malformed input tests, and real-node TCP Port-API validation.

Confirm:
- ToRadio.packet uses field 1.
- ToRadio.want_config_id uses field 3 / tag 0x18.
- FromRadio.channel uses field 10 / tag 0x52.
- channel discovery is disabled by default.
- read-only discovery sends want_config_id on connect, reconnect, and refresh.
- discovered channels are runtime-only.
- no raw PSKs are logged.
- no Crow config file is modified.

Final report:
- PASS/FAIL
- commit tested
- Meshtastic firmware version
- node IP
- exact config used
- commands run
- RX result
- TX result
- channel discovery result
- reconnect result
- config file mutation check result
- any fixes committed
```
