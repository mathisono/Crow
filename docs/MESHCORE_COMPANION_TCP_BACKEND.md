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

Expected inbound message flow:

```text
0x83  message waiting push
0x0A  Crow requests next queued message
0x07  direct/contact message
0x08  channel/group message
0x10  direct/contact message v3
0x11  channel/group message v3
0x0A  no more queued messages
```

Crow should keep requesting the next queued message until the no-more-messages response is received.

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
    "port": 4403
  }
}
```

Expected selector log in API mode:

```text
meshcore_backend: selected tcp backend
```

## Validation note

Validate this backend with Companion-framed packets. Do not use a line-oriented command probe as the pass/fail test for Crow's message bridge.
