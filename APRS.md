# Crow APRS Bridge

Crow can bridge APRS text messages through a configurable APRS backend. The default backend is APRS-IS, but the APRS module also includes support for Xastir/YAAC-style TCP text streams and Dire Wolf KISS-over-TCP.

APRS is public amateur-radio traffic. Keep transmit disabled until the station callsign, APRS-IS login/passcode or local TNC path, and operator control requirements are understood.

## Basic configuration

Add an `aprs` block to `raven.conf`. Crow creates and binds the default APRS
channel automatically, so it does not need to be duplicated in `channels`:

```json
{
  "callsign": "N0CALL-10",
  "aprs": {
    "enabled": true,
    "callsign": "N0CALL-10",
    "inline_max_members": 10,
    "backend": {
      "type": "aprsis",
      "host": "rotate.aprs2.net",
      "port": 14580,
      "tx_enabled": false
    }
  },
  "channels": [
    { "namekey": "AREDN og==", "telemetry": false }
  ]
}
```

The implicit channel is transport-aware: `APRS-IS-Feed` for APRS-IS,
`APRS-tcpKiss` for KISS TCP, and `APRS-TNC-Feed` for Xastir, YAAC, or a raw
TNC2 TCP stream. An explicit `aprs.channel` remains supported and always wins.
When multiple backends are configured, `aprs.default_backend` selects which
one owns the implicit channel; otherwise Crow uses the first configured
backend.

For APRS-IS transmit, set a valid APRS-IS passcode in the backend config and set `tx_enabled` to `true` only when ready.

## Backend types

APRS-IS:

```json
"backend": {
  "type": "aprsis",
  "host": "rotate.aprs2.net",
  "port": 14580,
  "passcode": "REPLACE_WITH_APRS_IS_PASSCODE",
  "filter": "b/N0CALL-4/N0CALL-7",
  "tx_enabled": true
}
```

Dire Wolf KISS TCP:

```json
"backend": {
  "type": "kiss_tcp",
  "host": "127.0.0.1",
  "port": 8001,
  "kiss_port": 0,
  "path": [],
  "tx_enabled": true
}
```

Authenticated Xastir server port:

```json
"backend": {
  "type": "xastir",
  "host": "127.0.0.1",
  "port": 2023,
  "passcode": "REPLACE_WITH_APRS_PASSCODE",
  "tx_enabled": true
}
```

Generic TNC2-style TCP server:

```json
"backend": {
  "type": "tcp_text",
  "host": "127.0.0.1",
  "port": 14580,
  "tx_enabled": true
}
```

Generic TNC2 TCP backends are raw local-client connections and do not receive
an APRS-IS login line. The explicit `xastir` backend authenticates with
Xastir's server port before transmitting. A packet accepted by a Xastir/YAAC TCP server only
appears on APRS-IS when that application is separately configured and enabled
to gate client-originated packets. If APRS-IS delivery is required regardless
of the local application's IGate policy, configure a second `aprsis` backend
and bind the transmitting channel or group to that backend.

Crow adds the `TCPIP*` path marker only when uploading directly to APRS-IS.
Packets injected into Xastir/YAAC omit it so the local application's IGate does
not reject them as packets that already traversed APRS-IS.

Crow keeps the configured backend key stable for channel mappings and derives
the user-facing backend label from the transport, backend key, and APRS
callsign. For example, backend key `xastir_dzb4` with callsign `KJ6DZB-10`
appears in Configure Channels as `aprs-tnc[xastir_dzb4] KJ6DZB-10`.

## Sending APRS messages

Use the configured APRS Crow channel, for example `APRS og==`.

Send a direct APRS message:

```text
@N0CALL-4 message text
```

Send to an existing configured group:

```text
#APRSgroup1 message text
```

Send to an inline list without changing the configured group:

```text
#APRSgroup1 N0CALL-4, N0CALL-7 message text
```

Create or update a runtime APRS group and send the message:

```text
join #APRSgroup1 N0CALL-4, N0CALL-7 message text
```

The `join` form creates `APRSgroup1` if it does not already exist, replaces its member list with the listed stations, and sends the message to those stations.

## Group repeat mode

Each group can optionally repeat received APRS messages from one group member back out to the other group members:

```json
{
  "name": "APRSgroup1",
  "members": [ "N0CALL-4", "N0CALL-7" ],
  "repeat_member_messages": true,
  "rate_limit_seconds": 20,
  "max_members": 10
}
```

When enabled, a message received from one group member is sent to the other group members, not back to the sender. Crow applies simple duplicate suppression and rate limiting to reduce loops.

Configured APRS groups automatically restore their AREDN-only `%Group og==`
channel during startup if an older channel override omitted it. This keeps the
group and repeat path active across base configuration and package upgrades.
