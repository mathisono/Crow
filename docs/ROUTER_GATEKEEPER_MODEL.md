# Router and Strict Gatekeeper Model

Status: **current branch routing model**.

Crow's router should not treat LoRa ingress as a general-purpose firehose.

For Meshtastic and MeshCore ingress, `router.uc` first decides whether the frame is in scope for this Crow node. Strict Gatekeeper then adds amateur-radio identity policy on top of that scope decision.

## Router responsibility

For LoRa ingress, router scope is intentionally small:

1. Accept direct messages meant for the connected Meshtastic/MeshCore bridge device.
2. Accept messages on joined group/channel paths.
3. Drop everything else before it can be forwarded.

Default joined channels include the public/default bridge channels loaded through config:

```text
LongFast AQ==                         Meshtastic public/default channel
MeshCore izOH6cXN6mrJ5e26oRXNcg==     MeshCore public/default channel
```

User-added channels may be added through the UI or slash commands. Once present in Crow's local channel table, those channels are valid ingress paths.

## Direct-message distinction: UDP vs TCP API

UDP backends can hear traffic that is not addressed to the local Crow bridge device. Therefore UDP direct frames must be addressed to Crow's local node/device identity before the router accepts them.

TCP/API backends are different. A TCP API backend is connected to a specific external radio/device API. Direct messages surfaced by that connected API are treated as local direct messages for this bridge path.

Current TCP API local-direct behavior:

```text
MeshCore TCP Companion API direct frame  -> local direct
Meshtastic TCP Port-API direct frame     -> local direct
```

Meshtastic TCP direct frames are marked with:

```text
metadata.local_direct = true
```

and the router also recognizes the TCP API backend names as local direct paths.

## What router drops

Router should drop LoRa ingress if it is not:

- a direct message for this bridge device; or
- a message on a configured local channel; or
- a MeshCore group message whose group slot resolves to a configured local channel.

Examples that should be dropped before forwarding:

```text
Meshtastic UDP frame for an unknown channel
MeshCore group message for an unmapped group slot
UDP LoRa direct frame not addressed to this node/device
Any LoRa frame with no matching local channel/default channel
```

Examples that should be accepted by scope before Strict Gatekeeper policy:

```text
Meshtastic TCP Port-API local direct frame
MeshCore TCP Companion local direct frame
Meshtastic public/default channel frame
MeshCore public/default channel frame
User-added local channel frame
Mapped MeshCore group-slot frame
```

## Where Strict Gatekeeper fits

Strict Gatekeeper is not the basic channel/direct-message scope filter.

It runs **after** router confirms that a LoRa frame is in scope.

Strict Gatekeeper then enforces:

- plain text only;
- no encrypted bridge forwarding;
- sender must have a callsign-looking identity;
- optional global callsign whitelist;
- optional per-channel callsign ACLs;
- gateway annotation such as `[SENDER via GATEWAY] message`.

## Current `router.uc` queue path

Current queue order:

```text
incoming backend message
  -> resolve MeshCore group slot if present
  -> LoRa ingress scope filter
       direct-to-bridge OR joined channel only
  -> Strict Gatekeeper channel ACL if enabled
  -> Strict Gatekeeper bridge filter if enabled
  -> de-duplicate by message id
  -> router process queue
```

## Strict Gatekeeper off

When `strict_gatekeeper.enabled=false`:

- LoRa ingress scope filtering still applies.
- Direct/local-channel matching still applies.
- Unknown channels and unmapped MeshCore group slots are still dropped.
- Callsign validation is skipped.
- Gateway annotation is skipped.

This means a packet can look valid at the LoRa protocol layer but still be dropped by router scope because it is not direct to the bridge device and is not on a joined channel.

## Strict Gatekeeper on

When `strict_gatekeeper.enabled=true`:

- LoRa ingress scope filtering still applies first.
- Channel ACLs apply after the scope filter.
- Meshtastic/MeshCore bridge filtering applies before the message enters the router queue.
- Accepted bridge messages are rewritten/annotated for gateway attribution.

## Backend pending drain

TCP/API backends can decode multiple messages from one socket read. The router now drains local backend pending queues before socket polling so decoded messages do not stall waiting for another socket event.

Current bounded drain behavior:

```text
MAX_PENDING_BACKEND_DRAIN = 4
```

The router calls pending-drain for:

```text
Meshtastic TCP Port-API
MeshCore TCP Companion API
```

The MeshCore backend also applies radio-side pull backpressure with `max_pending_rx`. Meshtastic Port-API is passive-stream based, so its pending drain is only a local decoded-message drain, not a radio-side queue pull.

## Per-channel ACL config shape

`gatekeeper.uc` must handle Crow's normal array-based `config.channels` shape:

```json
{
  "channels": [
    {
      "namekey": "AREDN-Local <base64-key>",
      "access_control": {
        "require_callsign": true,
        "allow": ["KJ6DZB", "W6*"],
        "deny": []
      }
    }
  ]
}
```

Aliases supported by the current code:

```text
allow              or allowed_callsigns
deny               or deny_callsigns
```

## Validation tests

### Router scope tests

Test with Strict Gatekeeper disabled first:

1. Meshtastic public/default channel frame is accepted.
2. MeshCore public/default channel frame is accepted.
3. User-added Meshtastic channel frame is accepted.
4. User-added MeshCore channel/group slot is accepted.
5. Unknown Meshtastic channel frame is dropped.
6. Unknown MeshCore group slot is dropped.
7. UDP direct Meshtastic/MeshCore frame not addressed to this node is dropped.
8. UDP direct Meshtastic/MeshCore frame addressed to this node is accepted.
9. Meshtastic TCP Port-API local direct frame is accepted.
10. MeshCore TCP Companion local direct frame is accepted.
11. Router drains local Meshtastic pending messages before socket polling.
12. Router drains local MeshCore pending messages before socket polling.
13. MeshCore TCP backpressure keeps `pending_rx <= max_pending_rx` during queue drain.

### Strict Gatekeeper tests

Enable Strict Gatekeeper and repeat accepted-path tests:

1. Valid callsign sender passes.
2. Invalid sender identity is dropped.
3. Sender not in global whitelist is dropped when whitelist is configured.
4. Channel deny list drops matching callsign.
5. Channel allow list permits matching callsign.
6. Channel allow list drops non-matching callsign.
7. Accepted text is annotated as `[SENDER via GATEWAY] message`.
8. MeshCore group text is weak-identity tagged.
9. Non-text LoRa bridge payload is dropped.
10. Encrypted bridge packet is dropped.

### Meshtastic TCP API validation additions

When test firmware/hardware is available for Meshtastic TCP Port-API:

1. Confirm `meshtastic_backend: selected tcp backend`.
2. Confirm Port-API connect to the configured host/port.
3. Send or replay multiple `FromRadio.packet` frames in one TCP read.
4. Confirm `meshtastic_API.pending()` becomes non-zero.
5. Confirm router drains pending Meshtastic messages without waiting for another socket event.
6. Confirm direct TCP Port-API messages are accepted as local direct messages.
7. Confirm unknown channel messages are still dropped by router scope.
8. Confirm Strict Gatekeeper still annotates accepted Meshtastic TCP ingress when enabled.

### Useful grep checks

```sh
grep -n 'filterLoRaIngressScope\|isDirectForLocalBridgeDevice\|isTcpApiIngress\|isJoinedBridgeChannel' router.uc
grep -n 'findChannelConfig\|allowList\|denyList' gatekeeper.uc
grep -n 'drainPendingBackend\|MAX_PENDING_BACKEND_DRAIN' router.uc
grep -n 'local_direct\|export function pending\|export function status' meshtastic_API.uc meshcore_tcp_api.uc
grep -n 'pending_rx\|sync_backpressure\|channels_discovered' meshtastic_backend.uc meshcore_backend.uc
```

Expected:

- router scope filtering exists before gatekeeper filtering;
- TCP API direct messages are recognized as local direct paths;
- gatekeeper can find channel ACLs in array-based config;
- backend pending drain remains bounded;
- Meshtastic and MeshCore TCP selectors expose pending/status telemetry.
