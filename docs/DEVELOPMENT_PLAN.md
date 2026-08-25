# Crow Development Plan

Status: **2026-08-25**  
Current source revision: `421aa78` — Implement MeshCore TCP and USB Companion backends

This is the current development and validation plan. Historical Raven migration notes remain in `CROW_MIGRATION_PLAN.md`; they are not the active feature plan.

## Release posture

The current revision is suitable for an experimental pre-release after the package is rebuilt. The MeshCore TCP and USB Companion paths are implemented and covered by local regression tests, but live RF validation remains pending.

Do not describe the MeshCore TCP/USB paths as production-ready until the hardware gates below pass.

## Workstreams

### 1. MeshCore TCP and USB hardware validation — pending

Validate both transports against real Companion hardware:

1. Build the current revision and record IPK/APK SHA256 values.
2. Deploy to a test AREDN node without overwriting unrelated local work.
3. Confirm startup, reconnect, self-info, channel discovery, bounded queue drain, and telemetry.
4. Capture representative `0x07`, `0x08`, `0x10`, `0x11`, `0x12`, and `0x83` frames.
5. Replay captured frames through the regression harness.
6. Confirm v3 payload layouts and discovery timing on the real device.
7. Repeat the transport checks over USB serial.

Current evidence: MSE-88 is reachable and can route to the AREDN test-node ports, but Hub5 currently rejects the available SSH credentials and the recorded MeshCore endpoint `10.245.94.47:4403` is unavailable. This workstream therefore remains **hardware validation pending**.

### 2. MeshCore direct identity — v1 verified, v2 pending

The first committed version is verified in the local test matrix:

- legacy direct frame addressed to the connected radio identity is accepted;
- legacy direct frame addressed elsewhere is not marked local and is dropped by router scope;
- modern Companion direct frames without an exposed destination remain explicitly unverified queue-origin ingress;
- direct replies require a learned sender public-key prefix.

The follow-up is to determine whether modern Companion hardware exposes a destination ID. If it does, pass it through the parser and remove the queue-origin fallback only after positive and negative RF tests pass. Do not change firmware as part of this Crow-side task.

### 3. Meshtastic TCP discovery — unchanged and experimental

Leave the existing read-only, runtime-only Meshtastic discovery implementation as-is. Its hardware validation and notification-parity work remain tracked in `MESHTASTIC_API_DISCOVERY_STATUS.md`.

Do not add persistent channel writes, radio write-back, or automatic routing enablement in this release.

### 4. Documentation and packaging — active cleanup

- Keep this file as the current plan.
- Keep MeshCore backend docs aligned with the implemented send path.
- Mark older validation reports as historical.
- Run UI/static checks, shell syntax checks, all Node regression tests, and the package build before cutting a release.
- Confirm generated packages contain the current UI, runtime modules, migration scripts, and generic Crow sysupgrade configuration.

### 5. GitHub issue cleanup — retired

Issue #1 about the custom firmware link is no longer an active Crow development task. The Crow backend uses the Companion binary API and does not require a firmware change for this implementation. Any firmware-specific compatibility question belongs in the hardware validation record.

## RF group-channel safety gate

RF group receive and send must remain intentionally unavailable until the same group channel is configured on both the radio and Crow. Channel discovery may report a runtime channel, but it must not silently join, persist, or enable it.

### Gate 0: disabled baseline

Before a matching channel is configured:

```json
{
  "meshcore": { "enabled": false },
  "meshcore_tcp_api": { "enabled": false }
}
```

Expected behavior:

- no MeshCore RF socket or serial transport is active;
- no Crow-originated group send is attempted;
- no RF group receive is routed into Crow.

### Gate 1: negative software tests

With the backend test harness enabled but no matching local channel:

- an inbound group frame whose `group_slot` has no Crow mapping is dropped by router scope;
- an outbound group message with no resolvable slot fails safely and increments the channel-send failure counter;
- a discovered radio channel remains runtime-only and does not modify Crow config;
- direct-message tests remain separate from group-channel tests.

### Gate 2: configure one matching group channel

Choose one radio group slot `N`. Configure that channel on the radio, then configure the exact same MeshCore channel name/key in Crow and explicitly map it to `N`:

```json
{
  "channels": [
    { "namekey": "<exact-radio-channel-name-and-key>" }
  ],
  "meshcore_tcp_api": {
    "enabled": true,
    "channel_discovery": true,
    "channel_slots": {
      "<exact-radio-channel-name-and-key>": N
    }
  }
}
```

The radio remains the authority for channel name, key, and slot. Crow must not invent a key or write the radio configuration.

### Gate 3: positive RF receive

Send a test message over RF on slot `N` and verify:

- the Companion frame decodes with `group_slot: N`;
- Crow resolves `N` to the configured local channel;
- the message appears only in that channel;
- an otherwise identical message on an unmapped slot is dropped;
- no raw PSK appears in logs, telemetry, or UI.

### Gate 4: positive RF send

Send a Crow message to the mapped local channel and verify:

- `CMD_SEND_CHANNEL_MESSAGE (0x03)` is built for slot `N`;
- the radio receives the message on the matching channel;
- `channel_sends_ok` increments;
- a Crow message targeting an unmapped channel does not produce an RF send and increments `channel_sends_failed` instead.

### RF gate acceptance

The RF work is complete only when the negative tests pass before configuration and the positive receive/send tests pass after the exact radio/Crow channel mapping is installed. Until then, release notes must say **hardware validation pending**.

## Required checks before release

```sh
node --check ui/ui.js
sh -n platforms/aredn/build.sh platforms/aredn/admin.sh \
  platforms/aredn/usb-setup.sh platforms/aredn/postinst \
  platforms/aredn/postinstall platforms/aredn/postupgrade \
  platforms/aredn/prerm
for f in tests/run_*.js; do node "$f" || exit $?; done
./platforms/aredn/build.sh
sha256sum crow_alpha.ipk crow-alpha.apk
```

The canonical `.uc` tests must also be run on a host or AREDN node with `ucode` available.
