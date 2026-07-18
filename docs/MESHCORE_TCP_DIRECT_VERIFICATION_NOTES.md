# MeshCore TCP Direct-Message Verification Notes

Status: current validation notes for `meshcore_tcp_api.uc`, `router.uc`, and `nodedb.uc`.

Crow receives direct frames from the connected MeshCore Companion queue as local direct messages. Modern direct frames include the sender public-key prefix; Crow remembers that prefix in `nodedb.uc` and uses it for direct replies.

## Implemented behavior

Direct receive and reply behavior:

1. Decode modern and legacy MeshCore direct receive frames from the Companion TCP API.
2. Store received direct messages with `metadata.local_direct = true` so `textmessage.uc` creates direct-message threads.
3. Remember the sender MeshCore public-key prefix when a modern direct frame provides it.
4. Send direct replies with `CMD_SEND_DIRECT_MESSAGE` only when a destination public-key prefix has been learned.
5. Fail direct sends safely and increment `direct_sends_failed` when the prefix is missing.

## Validation result

Validation target:

```text
Direct MeshCore TCP message from the connected Companion queue -> accepted as local direct ingress
Direct reply to a sender with a learned public-key prefix -> sent through CMD_SEND_DIRECT_MESSAGE
Direct reply without a learned public-key prefix -> fails safely
MeshCore TCP group message -> routes through public channel or group-slot mapping
```

## Related files

```text
meshcore_tcp_api.uc
router.uc
docs/ROUTER_GATEKEEPER_MODEL.md
```

## Notes

This is a Crow-side task only. Firmware changes are not required for the current implementation.
