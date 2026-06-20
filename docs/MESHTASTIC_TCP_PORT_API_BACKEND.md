# Meshtastic TCP Port-API Backend Plan

Status: **active experimental backend plan**.

Crow now keeps the existing Meshtastic UDP/multicast backend and the experimental Meshtastic TCP Port-API backend separate:

```text
meshtastic.uc       # existing UDP/multicast backend; keep unchanged
meshtastic_API.uc   # experimental TCP Port-API backend
```

The current development focus for `meshtastic_API.uc` is **read-only channel auto-discovery and periodic read-only refresh**. Do not implement two-way channel writes in this pass.

## Current direction

- Do not modify `meshtastic.uc`; it must remain the existing UDP/multicast backend.
- Do not wire `meshtastic_API.uc` into `router.uc` by default.
- Do not touch MeshCore for this task.
- Do not use Python, npm, protoc, generated protobuf files, or external protobuf libraries.
- Use pure ucode buffer parsing and the existing Crow coding style.
- Use Crow's existing `timers.setInterval()` / `timers.tick()` pattern.
- Do not introduce raw `uloop.timer` in this path unless the repo already uses it there.
- Do not implement serial support.
- Do not require MQTT.

## Current capability

`meshtastic_API.uc` already has first-pass TCP Port-API plumbing:

- maintains a TCP socket to a Meshtastic node on port `4403`;
- handles the `0x94 0xc3` Meshtastic TCP Port-API frame header;
- extracts payload lengths;
- decodes `FromRadio.packet`;
- sends outbound text using `ToRadio.packet`;
- keeps the original `meshtastic.uc` backend unchanged.

## Proposed experimental config

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

`channel_sync` must remain read-only or off for now. Bidirectional radio configuration writes are future work.

## Correct Meshtastic protobuf tags

Use these corrected field numbers and precomputed tags. Do not use older or generic Meshtastic field assumptions.

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

Important rejected assumptions:

- Do not treat `FromRadio.channel` as field 3.
- Do not treat `ToRadio.packet` as field 2.
- Do not assume the UDP backend's protobuf registration can safely cover TCP API config discovery.

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

The router should remain protocol-neutral.

## Implementation phases

### Phase 1: Fix core Port-API envelope protos

Update `meshtastic_API.uc` built-in proto registration:

- `fromradio` should include:
  - field 2: `proto packet packet`
  - field 7: `uint32 config_complete_id`
  - field 10: `proto channel channel`
- `toradio` should include:
  - field 1: `proto packet packet`
  - field 3: `uint32 want_config_id`

Preserve existing packet RX/TX behavior. Ensure outbound packet wrapping uses `ToRadio.packet` field 1.

Acceptance:

- inbound text packets still decode;
- outbound text still sends;
- `ToRadio.packet` no longer uses the old field-2 assumption;
- no changes are made to `meshtastic.uc`.

### Phase 2: Add lightweight TLV helpers

Add defensive local helpers in `meshtastic_API.uc`:

```ucode
readVarint(buf, off)
readLenDelimited(buf, off)
skipField(buf, off, wire_type)
extractChannels(buf)
```

Only protobuf wire types required in this pass:

- wire type 0: varint;
- wire type 2: length-delimited.

Requirements:

- check bounds before every read;
- reject varints longer than 10 bytes;
- reject length-delimited fields whose length exceeds remaining buffer;
- never throw on malformed data;
- return partial/null on malformed data;
- log bounded parser detail with `DEBUG2`, not byte-by-byte spam.

### Phase 3: Extract channel records

`extractChannels(buffer)` should scan a generic `FromRadio` payload:

1. Find tag `0x52` for `FromRadio.channel`.
2. Read the channel message length.
3. Inside the channel message, extract:
   - index from tag `0x08`;
   - settings block from tag `0x12`.
4. Inside settings, extract:
   - name from tag `0x1A`;
   - PSK from tag `0x22`.
5. Ignore all other fields.
6. Return an array like:

```ucode
[
  {
    index: 0,
    name: "LongFast",
    psk: <raw bytes>,
    psk_b64: <base64 string>,
    namekey: "LongFast <base64>"
  }
]
```

Do not log raw PSKs.

### Phase 4: Add runtime discovery map

Add a module-level map:

```ucode
let discoveredChannels = {};
```

Key it by channel index and/or channel name.

When a discovered channel arrives:

- ignore empty names;
- ignore empty PSKs unless the firmware uses a known default/public key representation;
- do not log raw PSKs;
- log only index, name, and whether it was added or updated;
- include only a short PSK hash/fingerprint if needed;
- add missing channels to `discoveredChannels`;
- update `discoveredChannels` if the PSK changes;
- do not write permanent config files.

### Phase 5: Integrate with Crow channel memory carefully

For this pass, do read-only runtime integration only.

Convert discovered channels to Crow-compatible `namekey` form:

```text
<channel-name> <base64-psk>
```

If a safe helper exists to register runtime/remote channel namekeys, use it. If no safe helper exists, keep the mapping internal to `meshtastic_API.uc` and add a TODO.

Rules:

- do not overwrite operator-configured Crow channels;
- do not mutate `config.channels`;
- do not persist to `/etc/crow.conf`;
- do not persist to Crow override files;
- do not auto-enable routing over newly discovered channels until validated.

### Phase 6: Send config request on connect

Add:

```ucode
function buildWantConfigId(id)
```

It should build:

- protobuf payload: tag `0x18` + varint request ID;
- Meshtastic TCP frame: `0x94 0xc3` + two-byte big-endian protobuf length + protobuf payload.

Add:

```ucode
function requestConfig(reason)
```

It should:

- generate a monotonic or random request ID;
- write the framed `want_config_id` request to the TCP socket;
- remember the last request ID;
- log the request ID and reason.

Call `requestConfig("connect")` immediately after TCP connect succeeds, but only when `channel_discovery` is true.

### Phase 7: Intercept channel/config frames

Update `decodeFromRadio(payload)`:

- packet frames still decode and queue as messages;
- channel frames update discovery state and return null;
- `config_complete_id` logs completion and returns null;
- unknown frames are ignored safely.

A channel frame must never be queued as a Crow message.

### Phase 8: Add periodic read-only refresh

Use Crow timers:

```ucode
timers.setInterval("meshtastic_API.channel_refresh", refresh_seconds)
```

In `tick()`, call:

```ucode
requestConfig("refresh")
```

when the timer fires and discovery is enabled.

Acceptance:

- discovery can be disabled entirely;
- no config requests are sent unless `channel_discovery` is true;
- refresh does not block the router event loop;
- reconnect triggers another connect-time config request;
- no persistent Crow config file is modified.

### Phase 9: Do not implement push/write sync yet

Do not write channel config back to the Meshtastic node in this pass.

Add TODO comments only:

```text
encodeChannelProto(index, name, psk)
admin/channel-set request
firmware compatibility testing
ACK/config-complete verification
operator confirmation before changing radio config
```

Two-way channel sync can change the physical LoRa radio configuration and must wait until read-only discovery is proven on hardware.

### Phase 10: Logging limits

Use:

- `DEBUG1` for channel added/updated/config complete;
- `DEBUG2` for skipped unknown fields and TLV parser detail;
- no raw PSK logs;
- no byte-by-byte config dump logs.

## Test plan

Add tests if practical:

- varint decode;
- length-delimited decode;
- malformed varint rejection;
- malformed length rejection;
- synthetic `FromRadio.channel` decode;
- `ToRadio.want_config_id` frame generation;
- packet RX still works;
- packet TX uses `ToRadio.packet` field 1;
- unknown fields are ignored;
- raw PSK is not printed.

Manual hardware validation:

1. Enable `meshtastic_api.channel_discovery=true`.
2. Manually wire the experimental backend only for the test.
3. Confirm TCP connect.
4. Confirm `want_config_id` is sent.
5. Confirm channel records arrive.
6. Confirm names/indexes are logged.
7. Confirm raw PSKs are not logged.
8. Confirm normal inbound text still routes.
9. Confirm outbound text still sends.
10. Confirm reconnect triggers another config request.
11. Confirm no persistent Crow config file is modified.

## OpenClaw implementation prompt

```text
You are an expert OpenWrt embedded systems engineer working on the Crow repo: mathisono/Crow.

I am re-architecting the experimental ucode backend: meshtastic_API.uc.

Current capability:
- Maintains a TCP socket to a Meshtastic node on port 4403.
- Handles the 0x94 0xc3 Meshtastic TCP Port-API frame header.
- Extracts payload lengths.
- Decodes FromRadio.packet.
- Sends outbound text using ToRadio.packet.

Current direction:
- Do not modify meshtastic.uc; it must remain the existing UDP/multicast backend.
- Do not wire meshtastic_API.uc into router.uc by default.
- Do not touch MeshCore for this task.
- Do not use Python, npm, protoc, generated protobuf files, or external protobuf libraries.
- Use pure ucode buffer parsing and the existing Crow coding style.
- Use Crow's existing timers.setInterval() / timers.tick() pattern. Do not introduce raw uloop.timer unless the repo already uses it in this path.

Goal:
Add read-only Meshtastic channel auto-discovery and periodic read-only channel refresh to meshtastic_API.uc.

Do not implement two-way channel sync in this pass.

Critical Meshtastic protobuf field numbers:
- FromRadio.packet = field 2, length-delimited, tag 0x12
- FromRadio.channel = field 10, length-delimited, tag 0x52
- FromRadio.config_complete_id = field 7, varint, tag 0x38
- ToRadio.packet = field 1, length-delimited, tag 0x0A
- ToRadio.want_config_id = field 3, varint, tag 0x18

Inside FromRadio.channel:
- index = field 1, varint, tag 0x08
- settings = field 2, length-delimited, tag 0x12

Inside settings:
- name = field 3, length-delimited string, tag 0x1A
- psk = field 4, length-delimited bytes, tag 0x22

Important:
Do not use older or generic Meshtastic field assumptions. Do not treat FromRadio.channel as field 3. Do not treat ToRadio.packet as field 2.

Implementation tasks:
1. Fix meshtastic_API.uc built-in envelope protos.
2. Add defensive local TLV helpers: readVarint, readLenDelimited, skipField, extractChannels.
3. Extract channel index, name, and PSK from FromRadio.channel.
4. Add runtime discoveredChannels map.
5. Convert discovered channels to Crow-compatible namekey form but do not persist or overwrite operator config.
6. Send ToRadio.want_config_id on connect when channel_discovery is true.
7. Intercept FromRadio.channel and config_complete_id in decodeFromRadio.
8. Add periodic read-only refresh using Crow timers.
9. Do not implement push/write sync yet; add TODOs only.
10. Limit logging and never print raw PSKs.
11. Add tests for TLV parser, want_config frame generation, and packet RX/TX preservation.

Docs:
After code is working, update Crow.wik/Meshtastic-API.md:
- read-only channel discovery supported when explicitly enabled
- periodic read-only refresh supported
- persistent channel sync not supported yet
- bidirectional writes are future work

Commit message:
Add read-only Meshtastic API channel discovery
```

## Release/merge checks

```sh
# Backend separation
grep -n "meshtastic_API" router.uc
grep -n "channel_discovery\|want_config_id\|0x52\|0x18" meshtastic_API.uc
grep -n "fromradio\|toradio" meshtasticprotobufs.uc

# Static syntax where available
ucode -R -L . meshtastic_API.uc
ucode -R -L . meshtastic.uc

# Package scripts
sh -n platforms/aredn/build.sh platforms/aredn/postinst platforms/aredn/postinstall platforms/aredn/postupgrade platforms/aredn/prerm
```

Expected:

- `router.uc` is not switched to `meshtastic_API.uc` by default.
- `meshtastic.uc` remains UDP/multicast.
- `meshtastic_API.uc` contains discovery code only when explicitly enabled.
- `meshtasticprotobufs.uc` does not register TCP API-only envelopes into the old UDP backend.
- No persistent Crow config files are modified by discovery.
