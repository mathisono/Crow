# MeshCore TCP Port-API Backend Plan

Status: **TNC/KISS path rejected; rework required for TCP Port-API backend**.

This document replaces the earlier MeshCore TNC/KISS backend plan. Crow should not use a TNC/KISS backend for MeshCore. The MeshCore backend needs to be reworked around a TCP Port-API style backend, matching the architectural direction now being used for Meshtastic.

## Current project decision

- Do **not** build or activate a MeshCore TNC/KISS backend.
- Do **not** parse MeshCore as a serial/TNC byte stream.
- Do **not** switch production routing to `meshcore_tnc`.
- Remove or retire the old TNC draft files after the TCP Port-API path is planned and replacement code is ready.
- Keep existing MeshCore behavior working until the new TCP backend is available.
- Focus current implementation work on Meshtastic TCP Port-API first.
- Return to MeshCore after Meshtastic TCP Port-API is stable.

## Relationship to Meshtastic work

Meshtastic is the current implementation focus. Its backend should prove the shared model first:

```text
TCP Port-API stream
  -> protocol-specific decode
  -> normalized Crow message
  -> strict gatekeeper / router decision
```

MeshCore should later follow the same pattern:

```text
MeshCore TCP backend stream
  -> MeshCore-specific decode
  -> normalized Crow message
  -> strict gatekeeper / router decision
```

Outbound path:

```text
Crow router message
  -> MeshCore backend send function
  -> MeshCore TCP backend encode/send
```

The router must remain protocol-neutral.

## Required future backend shape

When MeshCore is reworked, target the same Crow-facing interface expected from other backends:

```text
setup(config)
tick()
recv()
send(msg)
shutdown()
```

MeshCore-specific connection, framing, decoding, identity, and send behavior should stay in MeshCore-specific code. The router should only see normalized Crow messages.

## Proposed future config shape

Exact fields may change once the MeshCore TCP API is confirmed, but the config should follow the same explicit shape as Meshtastic:

```json
{
  "meshcore": {
    "enabled": true,
    "transport": "tcp",
    "host": "192.168.4.1",
    "port": 4403
  }
}
```

Rules:

- Use TCP as the target backend transport.
- Do not add serial/TNC config as the new path.
- Keep old MeshCore config only as compatibility fallback while migrating.
- Document the actual default port once confirmed against MeshCore hardware/software.

## TNC/KISS deprecation

The previous TNC/KISS plan is no longer the desired architecture.

Deprecated concepts:

- KISS frame unwrap/wrap as the main MeshCore backend.
- TNC command-byte routing.
- Serial/TNC stream parsing as the production path.
- `meshcore_tnc` as the future production module.
- Switching router imports from `meshcore` to `meshcore_tnc`.

If TNC draft files remain in the tree, treat them as historical experiments only. They should not be wired into production. After the TCP backend plan is implemented, remove stale TNC files or move them to an archive branch to avoid confusion.

## Future MeshCore TCP implementation phases

### Phase 0: wait until Meshtastic TCP backend is stable

Do not rework MeshCore until the Meshtastic TCP Port-API backend has proven:

- connection management
- decode path
- normalized Crow message path
- outbound send path
- reconnect/backoff behavior
- strict gatekeeper integration

### Phase 1: confirm MeshCore TCP API

Before coding, confirm the actual MeshCore TCP API details:

- host/IP discovery or configured host
- TCP port
- frame boundaries
- message envelope format
- text payload encoding
- node identity fields
- destination/broadcast model
- RSSI/SNR or link metric availability
- encrypted/unsupported payload behavior
- outbound send format

### Phase 2: connection skeleton

- Add explicit TCP config handling.
- Open persistent TCP connection.
- Add reconnect/backoff.
- Add debug logs for connect, disconnect, reconnect, retry.
- Do not route packets until decode is reliable.

### Phase 3: decode and normalize

Decode MeshCore TCP backend packets into normalized Crow messages including, where available:

- sender identity
- destination or broadcast
- channel/group/direct context
- text payload
- packet/message ID
- timestamp
- link metrics
- encrypted/unsupported state

Normalized object should follow current Crow router/message conventions and include the equivalent of:

```json
{
  "transport": "meshcore",
  "backend": "tcp-port-api",
  "from": 1234,
  "to": 4294967295,
  "packet_id": 123,
  "namekey": "MeshCore Primary",
  "data": {
    "text_message": "hello"
  }
}
```

### Phase 4: strict gatekeeper integration

Before a MeshCore-derived message is bridged into AREDN/Part 97 paths:

- verify packet decode succeeded
- preserve sender identity context when available
- mark weak identity clearly
- do not upgrade weak identity into strong identity without validation
- log drop reasons when strict gatekeeper rejects traffic

### Phase 5: outbound send

- Encode Crow-originated text for the MeshCore TCP backend.
- Support broadcast/group text first.
- Support direct text if the backend API and Crow model can safely identify the destination.
- Define deterministic behavior when disconnected: queue with bounds or drop with log.

### Phase 6: field validation

Validate with real MeshCore hardware/software:

- TCP connect works
- reconnect after device reboot works
- inbound text appears once
- outbound text sends once
- messages are not looped back incorrectly
- encrypted/unsupported packets are dropped/logged safely
- strict gatekeeper allow/drop behavior is visible in logs
- existing APRS, AREDN, and Meshtastic paths do not regress

## Cleanup plan for old TNC draft

After the TCP API path is confirmed:

1. Search for TNC/KISS files and references:

   ```sh
   find . -iname '*meshcore*tnc*' -o -iname '*kiss*'
   grep -Rni 'meshcore_tnc\|KISS\|TNC' .
   ```

2. Confirm none are imported by production code.
3. Remove stale TNC/KISS draft files from active tree or move them to an archive branch.
4. Update docs and config examples to mention TCP only.
5. Keep `meshcore.uc` or its TCP replacement as the active MeshCore module.

## OpenClaw prompt for later MeshCore rework

```text
In mathisono/Crow, rework MeshCore away from the old TNC/KISS draft plan and toward a TCP Port-API style backend. Do not use serial or TNC/KISS as the production backend.

Wait until the Meshtastic TCP Port-API backend pattern is stable, then apply the same architecture to MeshCore: TCP stream -> MeshCore-specific decode -> normalized Crow message -> strict gatekeeper/router. Outbound should use Crow router message -> MeshCore send function -> TCP encode/send.

Keep the router protocol-neutral. Keep MeshCore-specific connection/framing/decode logic inside MeshCore-specific files. Preserve existing MeshCore behavior until the TCP backend works. Remove or retire stale meshcore_tnc/KISS files only after confirming they are not imported by production code.

Add config under meshcore with enabled, transport="tcp", host, and port once the real MeshCore TCP API details are confirmed. Add reconnect/backoff, debug logging, safe packet drop behavior, strict_gatekeeper integration, and field validation notes.

Do not change APRS, AREDN, or Meshtastic behavior in this MeshCore cleanup pass.
```

## Current action

For now, treat MeshCore TCP as a future rework item. The active implementation task remains Meshtastic TCP Port-API.
