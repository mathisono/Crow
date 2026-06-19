# Meshtastic TCP Port-API Backend Plan

Status: **active backend plan**.

Crow's Meshtastic backend should move to a direct TCP Port-API connection to a Meshtastic ESP32 node. This is the current backend focus. MeshCore work is planned separately and should not be rewritten in this pass.

## Goal

Build a Meshtastic backend that talks directly to a Meshtastic node over TCP, decodes Port-API protobuf traffic, normalizes inbound packets into Crow messages, and sends Crow-originated messages back through the same connection.

This backend should not depend on MQTT and should not implement serial support.

## Non-goals

- Do not implement serial Meshtastic support.
- Do not use MQTT as the required Meshtastic path.
- Do not rewrite MeshCore during this pass.
- Do not mix MeshCore packet parsing into Meshtastic code.
- Do not remove APRS, AREDN, or existing MeshCore functionality.
- Do not forward unsupported/encrypted payloads unless Crow can safely identify and route them.

## Proposed config

```json
{
  "meshtastic": {
    "enabled": true,
    "transport": "tcp",
    "host": "192.168.4.1",
    "port": 4403
  }
}
```

Rules:

- `transport` should be `tcp`.
- Default TCP port is `4403`.
- `host` should be the Meshtastic node IP address.
- Old Meshtastic config keys can remain compatibility fallbacks, but new config should prefer this explicit TCP shape.

## Backend boundary

Meshtastic-specific work should stay inside `meshtastic.uc` or Meshtastic-specific helper modules.

Inbound path:

```text
TCP Port-API stream
  -> Meshtastic frame/protobuf decode
  -> normalized Crow message
  -> strict gatekeeper / router decision
```

Outbound path:

```text
Crow router message
  -> Meshtastic backend send function
  -> Meshtastic protobuf/frame encode
  -> TCP Port-API stream
```

The router should remain protocol-neutral.

## Required behavior

### Connection management

- Open a persistent TCP connection to `host:port`.
- Reconnect on disconnect.
- Use bounded reconnect/backoff.
- Do not block the main event loop.
- Log connect, disconnect, reconnect, and retry events.

### Inbound decode

Receive streamed Port-API protobuf packets and decode enough to identify:

- sender node ID
- destination node ID or broadcast
- channel/index if available
- text payload
- RSSI/SNR if available
- packet ID
- timestamp if available
- encrypted/unsupported packet state

Unsupported or encrypted payloads should be dropped or logged with a clear reason unless Crow can safely identify and route them.

### Normalized Crow message

Decoded Meshtastic text should normalize toward Crow's existing message shape. Exact field names should follow the current router/message conventions, but the normalized object should include the equivalent of:

```json
{
  "transport": "meshtastic",
  "backend": "tcp-port-api",
  "from": 123456789,
  "to": 4294967295,
  "packet_id": 123,
  "namekey": "Meshtastic LongFast",
  "rx": {
    "rssi": -72,
    "snr": 7.5
  },
  "data": {
    "text_message": "hello"
  }
}
```

### Outbound send

Crow-originated outbound text should be encoded and sent through the same TCP Port-API connection.

Required outbound cases:

- broadcast/channel text
- direct text if the current Crow model supports a destination
- send failure logging
- disconnected queue/drop behavior clearly documented in code comments

### Strict gatekeeper

Before any Meshtastic-derived message is bridged into AREDN/Part 97 paths:

- preserve strict-gatekeeper checks
- keep sender identity context when available
- do not upgrade weak identity into strong identity without validation
- log drop reasons when strict gatekeeper rejects traffic

## MeshCore relationship

MeshCore is planned for a later cleanup pass. During this Meshtastic work:

- leave `meshcore.uc` functional
- do not route MeshCore through Meshtastic code
- do not change MeshCore parser behavior unless required by a narrow bug fix
- keep the future shared backend shape in mind:

```text
setup(config)
tick()
recv()
send(msg)
shutdown()
```

## Suggested implementation phases

### Phase 1: config and connection skeleton

- Add explicit TCP config handling.
- Connect to `host:port`.
- Add reconnect/backoff.
- Add debug logs.
- Do not route packets yet unless decode is reliable.

Acceptance:

- Crow starts when Meshtastic is disabled.
- Crow attempts TCP connection when enabled.
- Disconnect/reconnect does not crash Crow.

### Phase 2: Port-API frame/protobuf decode

- Decode streamed Meshtastic packets.
- Identify text payloads.
- Identify unsupported/encrypted payloads and drop/log them.

Acceptance:

- Valid text packets become normalized Crow messages.
- Unsupported/encrypted packets do not crash or route incorrectly.

### Phase 3: router integration

- Feed normalized messages into the existing router path.
- Preserve strict gatekeeper behavior.
- Preserve current APRS/AREDN/MeshCore behavior.

Acceptance:

- Meshtastic inbound text appears in Crow using expected channels/directs.
- Gatekeeper can drop traffic based on configured policy.

### Phase 4: outbound send

- Encode Crow-originated text for Meshtastic.
- Send through TCP Port-API stream.
- Log send result.

Acceptance:

- Crow can send broadcast/channel text through Meshtastic.
- Direct send behavior is implemented or explicitly marked unsupported.
- Send while disconnected has deterministic behavior.

### Phase 5: test and field validation

- Add mock/dry-run decode tests if practical.
- Add debug capture logs for real device testing.
- Validate with ESP32 Wi-Fi enabled and Port-API reachable on TCP port `4403`.

Acceptance:

- RX text works.
- TX text works.
- Reconnect works.
- Unsupported/encrypted packet behavior is safe.
- Existing APRS/AREDN/MeshCore paths do not regress.

## OpenClaw implementation prompt

```text
In mathisono/Crow, start the backend rework by focusing only on the Meshtastic direct TCP backend. Do not rework MeshCore yet, but keep the design compatible with a later MeshCore backend cleanup.

Goal:
Move Meshtastic to a direct TCP Port-API backend that talks to the ESP32 Meshtastic node directly. Do not implement serial support.

Requirements:
- Use TCP only, default endpoint tcp://<meshtastic-ip>:4403.
- Add config: meshtastic.enabled, meshtastic.transport="tcp", meshtastic.host, meshtastic.port.
- Open and maintain a persistent TCP stream to the Meshtastic node.
- Receive streamed Port-API protobuf packets.
- Decode sender, destination/broadcast, channel, text payload, RSSI/SNR if available, packet ID, timestamp if available.
- Convert decoded packets into Crow's existing internal/router message shape.
- Send Crow-originated messages back through the same TCP stream.
- Handle disconnect/reconnect/backoff cleanly.
- Do not block the main event loop.
- Drop unsupported/encrypted payloads unless Crow can safely identify and route them.
- Preserve strict_gatekeeper checks before bridged messages are queued or forwarded.

Architecture:
- Keep Meshtastic framing/protobuf handling inside meshtastic.uc or Meshtastic-specific helpers.
- Router remains protocol-neutral.
- Use boundary: backend packet -> normalized Crow message -> router; router message -> backend send function.
- Do not mix MeshCore parsing into Meshtastic code.

MeshCore planning only:
- Leave MeshCore functional as-is.
- Do not rewrite MeshCore in this pass.
- Plan for MeshCore to later expose setup(config), tick(), recv(), send(msg), shutdown().

Testing:
- Add debug logging for connect, disconnect, reconnect, decode, packet drop reason, and send result.
- Add mock/dry-run decode tests if practical.
- Confirm text RX/TX, broadcast, direct message if supported, reconnect, and unsupported/encrypted packet handling.

Do not remove APRS, AREDN, or current MeshCore functionality.
Keep changes focused and reviewable.
Commit message: Add Meshtastic TCP Port-API backend
```

## Validation checklist

```sh
# Inspect Meshtastic/MeshCore separation
grep -n "meshcore" meshtastic*.uc
grep -n "meshtastic" meshcore*.uc

# Static syntax where available
ucode -R -L . meshtastic.uc

# Package scripts
sh -n platforms/aredn/build.sh platforms/aredn/postinst platforms/aredn/postinstall platforms/aredn/postupgrade platforms/aredn/prerm
```

Manual field checks:

- Meshtastic node Wi-Fi or LAN IP reachable.
- TCP port `4403` reachable from Crow host.
- Crow reconnects after Meshtastic node reboot.
- Inbound text appears once, not duplicated.
- Outbound text sends once, not looped back incorrectly.
- Unsupported/encrypted packet is dropped/logged safely.
- Strict gatekeeper drop/allow behavior is visible in logs.
