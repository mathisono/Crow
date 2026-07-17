# MeshCore Companion TCP Backend

Status: **Crow-side MeshCore Companion API backend direction**.

Crow's MeshCore TCP backend is `meshcore_tcp_api.uc`.

This backend is for the MeshCore **Companion binary API over TCP**. It is the message-bridge API for Crow.

## App goal

Crow should use the connected MeshCore node as a bridge device to:

1. monitor frames from the MeshCore node for messages on the MeshCore public channel and user-added/mapped channels;
2. send Crow messages out through those MeshCore channels;
3. receive direct messages delivered to the connected MeshCore node and create a direct-message thread for the sender;
4. send direct replies when the sender's MeshCore public-key prefix has been learned from an inbound direct message;
5. avoid becoming a blind bridge for unrelated LoRa traffic.

## Rule

Use the Companion TCP API for normal MeshCore message integration:

- direct message receive;
- direct message transmit when the destination public-key prefix is known;
- channel/group message receive;
- channel/group message transmit;
- queued message draining;
- future ACK/routing behavior;
- future diagnostics/status/control when available through Companion commands.

Do not use a line-oriented command/status API as the normal message bridge.

## Protocol shape

Crow expects Companion TCP frames:

```text
radio -> client:  '>' + uint16_le(length) + payload
client -> radio:  '<' + uint16_le(length) + payload
```

The payload starts with the Companion command or response code.

Crow startup frame currently used for app start:

```text
3c0c00010000000000000043726f77
```

This exact frame has been hardware-validated against the current RAK/Companion test node.

## Receive queue flow

Messages do **not** simply flow as an unbounded stream.

The Companion API uses a push-notify plus pull/drain model:

```text
0x83  message waiting push
0x0A  Crow requests next queued message
0x07  direct/contact message v1
0x08  channel/group message v1
0x10  direct/contact message v3
0x11  channel/group message v3
0x0A  no more queued messages
```

Crow keeps requesting queued messages until the no-more-messages response is received, but it does so with backpressure.

## Parser model

The backend now mirrors the MeshCoreOne-style separation more closely:

```text
TCP frame extraction
  -> response code classification
  -> direct/channel parser
  -> normalized Crow message
  -> router scope filter
  -> textmessage inbox storage
```

Supported message decode paths:

```text
0x07 direct/contact message v1
0x08 channel/group message v1
0x10 direct/contact message v3
0x11 channel/group message v3
```

The backend keeps a legacy fallback parser for earlier Crow tests/hardware assumptions, but the primary parser follows the Companion message layouts used by MeshCoreOne:

```text
Direct v3:
  SNR, reserved, sender prefix, path length, text type, timestamp, text

Channel v3:
  SNR, reserved, channel index, path length, text type, timestamp, text
```

Direct messages are normalized as local direct messages:

```text
namekey = DirectMessages <sender-id>
metadata.local_direct = true
```

On direct receive, Crow stores the sender's 6-byte MeshCore public-key prefix in `nodedb` so later direct replies can be sent with `CMD_SEND_MESSAGE`.

Channel messages keep their MeshCore channel index / group slot so router scope can allow the public channel and user-added/mapped channels while dropping unmapped slots.

## Known non-message frames

The backend no longer treats all non-message frames as unknown. It counts known Companion push/misc frames and rate-limits logs.

Important example:

```text
0x88 = log data
```

`0x88` frames are normal device log frames. They are counted but not logged repeatedly, preventing the AREDN node UI from being slowed by log spam.

Telemetry fields include:

```text
log_data_frames
trace_data_frames
telemetry_response_frames
binary_response_frames
control_data_frames
message_sent_frames
ack_frames
unknown_frames
unknown_frames_suppressed
```

## Backpressure

Crow should not pull the entire radio queue into the AREDN node as fast as the socket can deliver it.

Current Crow behavior:

- `0x83` starts a controlled drain;
- Crow sends one `CMD_SYNC_NEXT_MESSAGE` request at a time;
- Crow tracks whether a sync request is already in flight;
- Crow stores decoded messages in a bounded local `pendingRx` queue;
- Crow only asks for another message when the local pending queue is below `max_pending_rx`;
- router drains a small number of pending backend messages each tick so delivery does not stall if no new socket frame arrives.

Config example:

```json
{
  "meshcore": {
    "enabled": false
  },
  "meshcore_tcp_api": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 4403,
    "max_pending_rx": 4
  }
}
```

`max_pending_rx` defaults to `4` and is capped internally. Raise it only after testing memory and routing behavior on the target AREDN node.

Useful telemetry fields:

```text
pending_rx
max_pending_rx
message_waiting
sync_requests
sync_backpressure
no_more_messages
syncing_messages
sync_request_in_flight
sync_paused_backpressure
```

## Channel send

Crow can send text out through MeshCore channel slots using:

```text
CMD_SEND_CHANNEL_MESSAGE = 0x03
```

Payload format:

```text
byte 0       text type, 0x00 plain text
byte 1       channel index
bytes 2-5    Unix timestamp, uint32 little-endian
bytes 6+     UTF-8 text
```

The backend resolves channel index in this order:

1. `msg.group_slot` or `msg.channel_index` when already present;
2. runtime `discoveredChannels` map;
3. explicit `meshcore_tcp_api.channel_slots` / `channel_map` config;
4. public/default MeshCore channel -> slot `0`.

## Direct send

Crow can send direct text through MeshCore TCP when it has learned the target's public-key prefix from a prior inbound direct message.

Command:

```text
CMD_SEND_MESSAGE = 0x02
```

Payload format:

```text
byte 0       text type, 0x00 plain text
byte 1       retry attempt, currently 0 unless set on msg metadata
bytes 2-5    Unix timestamp, uint32 little-endian
bytes 6-11   destination public-key prefix, 6 bytes
bytes 12+    UTF-8 text
```

If the prefix is not known, Crow fails the direct send safely and increments `direct_sends_failed`. This avoids blind or malformed direct sends.

Direct-send telemetry:

```text
direct_sends_ok
direct_sends_failed
channel_sends_ok
channel_sends_failed
sends_ok
sends_failed
```

## Strict Gatekeeper identity rule

For the current pass, Strict Gatekeeper requires the sender callsign to appear in the bridged message text itself. Node names and stored contact metadata are not treated as sufficient identity for bridge forwarding yet.

Examples expected to pass callsign extraction:

```text
KJ6DZB radio check
radio check KJ6DZB
[KJ6DZB] radio check
```

Examples expected to drop when Strict Gatekeeper is enabled:

```text
radio check
net control here
unknown sender test
```

This conservative behavior applies to both direct and channel/group bridge ingress. Once MeshCore identity can be strongly tied to contacts/callsigns, this rule can be relaxed deliberately.

## Channel discovery notifications

The backend can request MeshCore Companion channel info using:

```text
CMD_GET_CHANNEL        = 0x1F
RESP_CODE_CHANNEL_INFO = 0x12
```

When `meshcore_tcp_api.channel_discovery=true`, Crow requests channel slots `0` through `15` after self-info is received and again on the refresh timer.

Discovery is paced one request at a time instead of blasting all slots at once.

Example config:

```json
{
  "meshcore": {
    "enabled": false
  },
  "meshcore_tcp_api": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 4403,
    "max_pending_rx": 4,
    "channel_discovery": true,
    "channel_refresh_seconds": 600
  }
}
```

Channel discovery is runtime-only in this pass. It does not write Crow config. It maps a discovered channel slot only when that channel is already one of Crow's local channels. New/unknown channel discoveries notify the operator, but do not silently join or persist the channel.

When a new or changed channel is discovered, the backend emits an operator notification through Crow's existing websocket command-reply path:

```text
MeshCore TCP API discovered channel
Index N: ChannelName
Runtime only; not saved to Crow config.
```

Telemetry fields:

```text
channel_discovery
channel_scans
channel_discovery_requests
channel_info_responses
channel_discovery_timeouts
channels_discovered
channels_updated
```

## Future command/status API

If a diagnostic or status feature cannot be provided through the Companion API, document that gap first.

Only then consider a separate optional Crow backend such as:

```text
meshcore_command_api.uc
```

Rules for that future backend:

- it must be opt-in;
- it must not replace `meshcore_tcp_api.uc`;
- it must not carry normal MeshCore message traffic;
- it must not be selected by default;
- it must be documented separately.

## Validation note

Validate this backend with Companion-framed packets. Do not use a line-oriented command probe as the pass/fail test for Crow's message bridge.

The repo includes a validation helper:

```sh
python3 tools/test_meshcore_companion.py DEVICE_IP --port 4403
```

It sends the full framed startup command:

```text
3c0c00010000000000000043726f77
```

To also exercise the queue-drain request after a `0x83` message-waiting push:

```sh
python3 tools/test_meshcore_companion.py DEVICE_IP --port 4403 --drain-on-83 --max-frames 20
```

Message reception validation should confirm:

- `0x83` is treated as a notification, not a message payload;
- Crow sends `0x0A` to request the next queued message;
- direct v1/v3 messages decode into `DirectMessages <sender>`;
- channel v1/v3 messages decode with a channel index / group slot;
- channel messages on slot `0` reach the MeshCore public channel;
- mapped user-added channel slots reach the mapped local channel;
- Crow stops when `0x0A` no-more-messages is received;
- `sync_backpressure` remains low during normal use;
- `pending_rx` does not grow without bound.

Send validation should confirm:

- sending to the MeshCore public channel uses slot `0`;
- sending to a discovered/mapped channel uses that channel index;
- receiving a direct message stores a MeshCore public-key prefix for the sender;
- replying to that direct thread sends `CMD_SEND_MESSAGE 0x02`;
- direct send without a learned prefix fails safely and increments `direct_sends_failed`;
- `direct_sends_ok` / `channel_sends_ok` / failure counters change correctly.

Strict Gatekeeper validation should confirm:

- messages containing a valid callsign in the body pass, subject to whitelist/ACLs;
- messages without a callsign in the body drop when strict mode is enabled;
- group/channel messages use the body callsign for weak gateway attribution;
- node names alone do not satisfy strict identity in this pass.

Channel discovery validation should confirm:

- `channel_discovery=true` sends paced `CMD_GET_CHANNEL` requests for slots `0` through `15`;
- `RESP_CODE_CHANNEL_INFO` increments `channel_info_responses`;
- a new channel increments `channels_discovered`;
- a changed channel increments `channels_updated`;
- operator notification appears in the UI command-reply area;
- no raw channel secret is printed in logs or UI;
- no Crow config file is modified.
