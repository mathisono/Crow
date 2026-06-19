# MeshCore Backend Hold Note

Status: **on hold**.

This document corrects the MeshCore position: the current TCP Port-API backend plan applies to **Meshtastic only**. MeshCore is not part of the current TCP Port-API implementation pass.

## Current project decision

- MeshCore is on hold.
- Do not build or activate a MeshCore TNC/KISS backend.
- Do not parse MeshCore as a serial/TNC byte stream.
- Do not rework MeshCore around the Meshtastic TCP Port-API plan.
- Do not switch production routing to `meshcore_tnc`.
- Do not touch `meshcore.uc` unless a narrow bug fix is required to keep existing behavior working.
- Keep existing MeshCore behavior available while Meshtastic is reworked.
- Focus current implementation work on the Meshtastic TCP Port-API backend only.

## Rejected MeshCore direction

The older MeshCore TNC/KISS plan is rejected for the current Crow direction.

Rejected concepts:

- KISS frame unwrap/wrap as the MeshCore backend.
- TNC command-byte routing.
- Serial/TNC stream parsing as a production MeshCore path.
- `meshcore_tnc` as a production module.
- Router import switch from `meshcore` to `meshcore_tnc`.

If TNC draft files remain in the tree, treat them as historical experiments only. They should not be wired into production. Remove or archive them later only after confirming they are not imported by production code.

## Active backend work

The active backend work is documented in:

```text
docs/MESHTASTIC_TCP_PORT_API_BACKEND.md
```

That plan is Meshtastic-specific:

```text
Meshtastic TCP Port-API stream
  -> Meshtastic-specific frame/protobuf decode
  -> normalized Crow message
  -> strict gatekeeper / router decision
```

Do not generalize that into a MeshCore TCP Port-API requirement until MeshCore is deliberately reopened as a separate design task.

## MeshCore future posture

When MeshCore work resumes, start from a fresh hardware/API assessment rather than the old TNC/KISS draft.

Questions to answer later:

- What is the supported MeshCore host/device API?
- Is there a stable network API, bridge API, or other integration point?
- What transport is actually supported by the target MeshCore hardware/software?
- What message envelope is available?
- How are sender identity, destination, channel/group, and encrypted state represented?
- How should strict gatekeeper evaluate MeshCore-originated messages?

Until those are answered, MeshCore should remain unchanged.

## Cleanup plan for old TNC draft files

Later, after confirming they are unused:

```sh
find . -iname '*meshcore*tnc*' -o -iname '*kiss*'
grep -Rni 'meshcore_tnc\|KISS\|TNC' .
```

Then either delete stale TNC/KISS draft files from the active tree or move them to an archive branch. Do not do this as part of the Meshtastic TCP Port-API coding pass unless specifically requested.

## Current action

Code the Meshtastic TCP Port-API backend first. Leave MeshCore alone.
