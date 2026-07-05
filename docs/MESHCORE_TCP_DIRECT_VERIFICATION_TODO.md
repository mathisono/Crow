# MeshCore TCP Direct-Message Verification TODO

Status: follow-up item for `meshcore_tcp_api.uc` and `router.uc`.

The current branch accepts MeshCore TCP Companion direct messages as local direct messages because they are surfaced by the connected Companion API device queue.

That is acceptable for hardware bring-up, but it should be improved before treating the TCP backend as production-ready.

## Current behavior

```text
transport = meshcore
backend   = tcp_api
non-group direct-looking message
=> router treats it as local direct ingress
```

Reason:

```text
Crow is connected to one external MeshCore radio/device Companion API queue, so messages surfaced by that queue are presumed to belong to the connected bridge device.
```

## Desired improvement

Improve the backend so it verifies direct-message destination against the connected MeshCore radio/device identity.

Target design:

1. Learn the connected MeshCore radio/device node id from self-info or an explicit Companion API identity command.
2. Store that identity in `meshcore_tcp_api.uc`.
3. Mark `metadata.local_direct = true` only when the decoded direct message destination matches the learned radio/device id.
4. Update `router.uc` to prefer `metadata.local_direct` instead of trusting only the backend name.
5. Remove or demote the current backend-name fallback after hardware validation confirms self-id matching works.

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
