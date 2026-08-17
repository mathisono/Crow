# MeshCore TCP Direct-Message Verification TODO

Status: partially implemented for legacy direct frames in `meshcore_tcp_api.uc`
and enforced by `router.uc`; modern Companion direct frames still need hardware
validation because the current parser does not expose an explicit destination id
for that format.

Legacy MeshCore TCP direct-message destinations are already verified when the
connected radio/device identity is known from self-info.

Modern Companion direct frames are still accepted as local direct messages
because they are surfaced by the connected Companion API device queue and this
Crow-side parser currently only sees the sender prefix, not a destination id.

## Current behavior

```text
transport = meshcore
backend   = tcp_api
non-group direct-looking message
direct_identity_verified = true
local_direct = false
=> router drops it
```

Reason:

```text
Legacy direct frames carry `to`, so Crow compares that destination against the
id derived from the connected radio/device public-key prefix learned from
self-info. Frames without an exposed destination keep the existing queue-origin
fallback for bring-up.
```

## Desired improvement

Improve the backend so it verifies direct-message destination against the connected MeshCore radio/device identity.

Target design:

1. Confirm on hardware whether modern Companion direct frames expose the
   destination id through another command/format variant.
2. If available, pass that destination into `directMsg()`.
3. Mark `metadata.local_direct = true` only when the decoded direct message
   destination matches the learned radio/device id.
4. Remove or demote the current queue-origin fallback after hardware validation
   confirms self-id matching works for all direct formats.

## Validation target

After this follow-up is implemented:

```text
Direct MeshCore TCP message where msg.to == connected radio/device id -> accepted
Direct MeshCore TCP message where msg.to != connected radio/device id -> dropped
MeshCore TCP group message -> still requires group_slot mapped to a local Crow channel
```

## Related files

```text
meshcore_tcp_api.uc
router.uc
docs/ROUTER_GATEKEEPER_MODEL.md
```

## Notes

This is a Crow-side task only. Do not change firmware while implementing this router/backend verification improvement unless a later task explicitly asks for firmware work.
