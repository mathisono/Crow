# MeshCore TCP Direct-Message Verification TODO

Status: **v1 implemented and locally verified; protocol-limited v2 policy is
implemented, while destination-bearing modern hardware validation remains
pending.** Legacy direct frames are enforced by `router.uc`.

Legacy MeshCore TCP direct-message destinations are already verified when the
connected radio/device identity is known from self-info.

Modern Companion direct frames are accepted as explicitly unverified local
direct messages in compatibility mode because they are surfaced by the
connected Companion API device queue and the parser only sees the sender
prefix, not a destination id. Strict verified mode is available for
deployments that prefer to drop those frames.

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
self-info. Frames without an exposed destination use the queue-origin fallback
only when `direct_identity_mode` is `"compatibility"`; verified mode drops
them.
```

## V1 verification result

The current regression matrix verifies that:

- a legacy direct destination matching the connected radio identity is accepted;
- a verified destination mismatch is not local and is dropped by router scope;
- modern direct frames without an exposed destination remain explicitly
  unverified queue-origin ingress;
- direct replies fail safely until a sender public-key prefix is learned.

## V2 hardware follow-up

Confirm whether modern hardware exposes a destination-bearing format and wire
it into the already available strict policy.

Target design:

1. Confirm on hardware whether modern Companion direct frames expose the
   destination id through another command/format variant.
2. If available, pass that destination into `directMsg()`.
3. Mark `metadata.local_direct = true` only when the decoded direct message
   destination matches the learned radio/device id.
4. Remove or demote the current queue-origin fallback after hardware validation
   confirms self-id matching works for all direct formats.

## Validation target

After hardware exposes and Crow verifies the destination for modern frames:

```text
Direct MeshCore TCP message where msg.to == connected radio/device id -> accepted
Direct MeshCore TCP message where msg.to != connected radio/device id -> dropped
MeshCore TCP group message -> still requires an exact discovered radio/Crow name-key-slot match
```

## Related files

```text
meshcore_tcp_api.uc
router.uc
docs/ROUTER_GATEKEEPER_MODEL.md
```

## Notes

This is a Crow-side task only. Do not change firmware while implementing this router/backend verification improvement unless a later task explicitly asks for firmware work.
