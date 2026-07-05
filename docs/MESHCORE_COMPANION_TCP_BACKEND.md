# MeshCore Companion TCP Backend

Status: **Crow-side backend direction**.

Crow's MeshCore TCP backend is `meshcore_tcp_api.uc`.

This backend is for the MeshCore **Companion binary API over TCP**. It is the message-bridge API for Crow.

## Rule

Use the Companion TCP API for normal MeshCore message integration:

- direct message receive;
- channel/group message receive;
- direct message transmit;
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

## Receive queue flow

Messages do **not** simply flow as an unbounded stream.

The Companion API uses a push-notify plus pull/drain model:

```text
0x83  message waiting push
0x0A  Crow requests next queued message
0x07  direct/contact message
0x08  channel/group message
0x10  direct/contact message v3
0x11  channel/group message v3
0x0A  no more queued messages
```

Crow should keep requesting queued messages until the no-more-messages response is received, but it must do so with backpressure.

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

## Channel discovery notifications

The backend can request MeshCore Companion channel info using:

```text
CMD_GET_CHANNEL        = 0x1F
RESP_CODE_CHANNEL_INFO = 0x12
```

When `meshcore_tcp_api.channel_discovery=true`, Crow requests channel slots `0` through `7` after self-info is received and again on the refresh timer.

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

Channel discovery is runtime-only in this pass. It does not write Crow config and does not auto-map MeshCore group slots.

When a new or changed channel is discovered, the backend emits an operator notification through Crow's existing websocket command-reply path:

```text
MeshCore TCP API discovered channel
Index N: ChannelName
Runtime only; not saved to Crow config.
```

Telemetry fields:

```text
channel_discovery
channel_discovery_requests
channel_info_responses
channels_discovered
channels_updated
```

## Direct-message acceptance TODO

Current first-pass behavior accepts direct frames from the connected MeshCore Companion TCP API as local direct messages because they come from that radio's local API queue.

This should be improved before production use:

1. Parse or query the connected MeshCore device/node id from Companion self-info or another Companion command.
2. Mark `metadata.local_direct=true` only when the direct message destination matches that connected device id.
3. Update `router.uc` to prefer `metadata.local_direct` over backend-name trust.
4. Keep the current TCP backend direct acceptance only as a compatibility fallback during hardware validation.

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

## Config

Default MeshCore remains UDP:

```json
{
  "meshcore": {
    "enabled": true
  }
}
```

Experimental Companion TCP API:

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

Expected selector log in API mode:

```text
meshcore_backend: selected tcp backend
```

## Validation note

Validate this backend with Companion-framed packets. Do not use a line-oriented command probe as the pass/fail test for Crow's message bridge.

Message reception validation should confirm:

- `0x83` is treated as a notification, not a message payload;
- Crow sends `0x0A` to request the next queued message;
- direct/group messages are decoded and queued;
- Crow stops when `0x0A` no-more-messages is received;
- `sync_backpressure` remains low during normal use;
- `pending_rx` does not grow without bound.

Channel discovery validation should confirm:

- `channel_discovery=true` sends `CMD_GET_CHANNEL` for slots `0` through `7`;
- `RESP_CODE_CHANNEL_INFO` increments `channel_info_responses`;
- a new channel increments `channels_discovered`;
- a changed channel increments `channels_updated`;
- operator notification appears in the UI command-reply area;
- no raw channel secret is printed in logs or UI;
- no Crow config file is modified.
