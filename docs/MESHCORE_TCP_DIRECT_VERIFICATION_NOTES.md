# MeshCore TCP Direct-Message Verification Notes

Status: current validation notes for the direct-message verification path in
`meshcore_tcp_api.uc`, `router.uc`, and `nodedb.uc`.

The current implementation was verified locally. Live hardware verification
of modern Companion destination fields is still pending; the protocol
currently exposes only the sender prefix for the modern frame shape.

Crow receives direct frames from the connected MeshCore Companion queue as
local direct messages. Legacy direct frames carry a destination id; when Crow
has learned the connected radio public-key prefix from self-info, it verifies
that destination before marking the frame local. Modern direct frames include
the sender public-key prefix; Crow remembers that prefix in `nodedb.uc` and
uses it for direct replies, but the current parser does not expose a
destination id for that format.

## Implemented behavior

Direct receive and reply behavior:

1. Decode modern and legacy MeshCore direct receive frames from the Companion TCP API.
2. Mark legacy direct messages with `metadata.direct_identity_verified = true`
   when a destination id can be compared against the connected radio identity.
3. Keep accepting unverified queue-origin modern direct frames with
   `metadata.local_direct = true` in compatibility mode so `textmessage.uc`
   creates direct-message threads during bring-up. Strict verified mode drops
   modern frames that lack a destination.
4. Remember the sender MeshCore public-key prefix when a modern direct frame provides it.
5. Send direct replies with `CMD_SEND_DIRECT_MESSAGE` only when a destination public-key prefix has been learned.
6. Fail direct sends safely and increment `direct_sends_failed` when the prefix is missing.

Status counters exposed by `meshcore_tcp_api.status()`:

```text
direct_identity_verified    legacy direct frames checked against self identity
direct_identity_mismatch    checked legacy direct frames that did not target self
direct_identity_unverified  direct frames accepted through queue-origin fallback
direct_identity_dropped     modern frames dropped by strict verified mode
```

## Validation result

Validation target:

```text
Legacy direct where destination matches connected radio identity -> accepted as local direct ingress
Legacy direct where destination does not match connected radio identity -> dropped by router scope
Modern direct from the connected Companion queue without exposed destination -> accepted as unverified local direct ingress
Direct reply to a sender with a learned public-key prefix -> sent through CMD_SEND_DIRECT_MESSAGE
Direct reply without a learned public-key prefix -> fails safely
MeshCore TCP group message -> routes only after an exact discovered radio/Crow name-key-slot match
```

## Related files

```text
meshcore_tcp_api.uc
router.uc
docs/ROUTER_GATEKEEPER_MODEL.md
```

## Notes

This is a Crow-side task only. Firmware changes are not required for the current implementation.
