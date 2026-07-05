# Router and Strict Gatekeeper Model

Status: **current branch routing model**.

Crow's router should not treat LoRa ingress as a general-purpose firehose.

For Meshtastic and MeshCore ingress, `router.uc` should first decide whether the frame is in scope for this Crow node. Strict Gatekeeper then adds amateur-radio identity policy on top of that scope decision.

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

## What router drops

Router should drop LoRa ingress if it is not:

- a direct message for this bridge device; or
- a message on a configured local channel; or
- a MeshCore group message whose group slot resolves to a configured local channel.

Examples that should be dropped before forwarding:

```text
Meshtastic UDP frame for an unknown channel
MeshCore group message for an unmapped group slot
LoRa direct frame not addressed to this node/device
Any LoRa frame with no matching local channel/default channel
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

## Strict Gatekeeper on

When `strict_gatekeeper.enabled=true`:

- LoRa ingress scope filtering still applies first.
- Channel ACLs apply after the scope filter.
- Meshtastic/MeshCore bridge filtering applies before the message enters the router queue.
- Accepted bridge messages are rewritten/annotated for gateway attribution.

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
7. Direct Meshtastic frame not addressed to this node is dropped.
8. Direct Meshtastic frame addressed to this node is accepted.
9. MeshCore TCP direct frame from the connected Companion queue is accepted.

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

### Useful grep checks

```sh
grep -n 'filterLoRaIngressScope\|isDirectForLocalBridgeDevice\|isJoinedBridgeChannel' router.uc
grep -n 'findChannelConfig\|allowList\|denyList' gatekeeper.uc
grep -n 'drainPendingBackend\|MAX_PENDING_BACKEND_DRAIN' router.uc
```

Expected:

- router scope filtering exists before gatekeeper filtering;
- gatekeeper can find channel ACLs in array-based config;
- backend pending drain remains bounded.
