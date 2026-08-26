# Crow Development Plan

Status: **2026-08-26**
Current source revision: release-hardening work — exact-match RF gate, bounded
channel datagrams, direct-identity policy, and GUI transport validation

This is the current development and validation plan. Historical Raven migration notes remain in `CROW_MIGRATION_PLAN.md`; they are not the active feature plan.

## Release posture

The current revision is suitable for a release candidate after the package is
rebuilt and the remaining hardware gates are recorded. MeshCore TCP/bridge
transport and GUI-to-GUI messaging are proven in both directions. One tagged
air-to-Crow receive path has also been observed on BB5MC; the complete
bidirectional RF acceptance record and native direct-USB path remain open.

Do not describe native direct USB or full bidirectional RF as production-ready
until the hardware gates below pass.

## Workstreams

### 1. MeshCore transport hardware validation — split status

Validate both transports against real Companion hardware:

1. Build the current revision and record IPK/APK SHA256 values.
2. Deploy to a test AREDN node without overwriting unrelated local work.
3. Confirm startup, reconnect, self-info, channel discovery, bounded queue drain, and telemetry.
4. Capture representative `0x07`, `0x08`, `0x10`, `0x11`, `0x12`, and `0x83` frames.
5. Replay captured frames through the regression harness.
6. Confirm v3 payload layouts and discovery timing on the real device.
7. Repeat the transport checks over USB serial.

Current evidence (2026-08-26): the supervised BB5MC TCP/serial bridge path
connects, discovers the exact public-channel tuple, and carries the tested
GUI-to-GUI flow. The final tagged A2B air message was observed through Crow on
BB5MC. The bridge path is therefore **validated for the recorded test scope**;
native direct USB remains **hardware validation pending**.

Second-node update (2026-08-25/26): `KJ6DZB-BB5MC` (`10.52.8.205`, Basbox5)
now has the AREDN USB-serial kernel modules installed and exposes the attached
RAK4631 as `/dev/ttyACM1` after USB re-enumeration. Its slot-0 `Public` channel
matches Crow's configured public-channel tuple (the key is intentionally not
recorded here). Raw Companion
capture has produced a channel receive frame (`0x08`) and queue-empty replies
(`0x0A`), proving that the radio can receive and drain public-channel traffic.
Crow package `0.0.2-r20512923` is deployed with a dedicated USB serial module:
one update-stream descriptor, timer-driven bounded one-byte drains, bounded
frame deferral, startup/periodic queue polling, a character-device guard, and
the MIPS `crow-rawtty` ioctl helper
required by the minimal AREDN image. The service remains running and the
GUI/event loop remains responsive.
The initial Crow startup sent `CMD_APP_START` during the RAK CDC reset window,
which made app-start, channel-query, and queue-sync probes appear silent. An
independent MIPS probe then returned `RESP_SELF_INFO (0x05)` and all eight
channel records after a two-second USB settle. Crow `0.0.2-r20512923` now uses
that settle window and live BB5MC logs show the connected device, `Public`
channel discovery, and queue polling. The independent native direct-USB
attempt is retained as a release blocker: the device opened and accepted
writes, but no self-info or RF frame was observed through Crow after bounded
handshake retries. The node was restored to the proven supervised bridge
configuration. Do not claim direct USB from the open device or handshake
counters alone.

### 2. MeshCore public-channel inbound receive path — A2B observed; B2A closeout pending

The public channel is present in Crow with the exact discovered radio tuple, but
live receive needs a controlled sender/receiver test. A second AREDN node is
preferred when available, provided it has an independent MeshCore radio or
Companion endpoint; two Crow instances connected to the same radio do not test
RF receive.

Validation plan:

1. Configure Node A and Node B with separate MeshCore radios, distinct device
   identities, and the same public channel.
2. Send timestamped messages A → B and B → A repeatedly, recording whether each
   message appears in Crow.
3. Capture the raw Companion frames on both nodes, including channel text
   frames (`0x08`/`0x11`), channel datagrams (`0x1B`), message-waiting pushes
   (`0x83`), and queue-empty responses (`0x0A`).
4. Verify that Crow performs a bounded queue poll after connection and handles
   inbound traffic when no `0x83` push is emitted.
5. If public traffic arrives as `0x1B`, implement and test its decoder and map
   the decoded slot only through the exact discovered name/key/slot tuple.
6. Replay captured frames through the regression harness and repeat the
   bidirectional RF test.

Acceptance: repeated bidirectional public-channel messages are received by the
intended Crow channel, no messages appear on an unintended channel, and the
backend exposes enough counters/logging to distinguish RF loss from Companion
queue or parser loss. Until this test is available and passes, inbound RF
validation remains **pending**.

Current evidence: tagged `RF-AIR-A2B-20260826T195700` was decoded from a real
Companion `0x08` frame and delivered through Crow on BB5MC. This closes the
one-direction receive observation, but the full RF gate remains open until the
reverse tagged direction is recorded as well. The official Companion layout
for `RESP_CHANNEL_DATA_RECV (0x1B)` is implemented as bounded, opt-in
application text; it is not used as proof unless the configured data type is
known and the exact channel tuple passes.

#### Final tagged air test

Use two independent radios, both on the exact discovered public-channel
tuple. From Node A send a short body containing the sender identity and a
unique token, for example `KJ6DZB@MCGW> RF-AIR-A2B-<timestamp>`. From Node B
send `KN6PLV@MCGW> RF-AIR-B2A-<timestamp>`. The tags are test payload content;
the Companion transport itself is not considered RF evidence until each body
is visible in the other node's Crow channel.

For each direction, record the radio's Companion frame code, Crow's
`frames_in`/`frames_decoded` counters, the exact mapped channel, and the stored
message or UI event. A pass requires both unique tokens to appear through
Crow, with no delivery to an unmapped slot. If strict gatekeeper is enabled,
the embedded sender callsign must also pass its callsign/allow-list checks.

### 3. MeshCore direct identity — compatibility and strict policy implemented

The first committed version is verified in the local test matrix:

- legacy direct frame addressed to the connected radio identity is accepted;
- legacy direct frame addressed elsewhere is not marked local and is dropped by router scope;
- modern Companion direct frames without an exposed destination remain explicitly unverified queue-origin ingress;
- direct replies require a learned sender public-key prefix.

Modern Companion frames still expose no destination ID in the documented
shape. Compatibility mode preserves queue-origin behavior for bring-up;
`direct_identity_mode: "verified"` / `strict_direct_identity: true` now drops
modern frames that cannot be destination-verified. Hardware discovery of a
destination-bearing format remains a follow-up; no firmware change is needed.

### 4. Meshtastic TCP discovery — notification parity complete; hardware pending

The read-only runtime parser now has operator notification parity and
`channels_updated` telemetry. Hardware validation remains pending and the
feature stays experimental.

Do not add persistent channel writes, radio write-back, or automatic routing enablement in this release.

### 5. Documentation and packaging — active release cleanup

- Keep this file as the current plan.
- Keep MeshCore backend docs aligned with the implemented send path.
- Mark older validation reports as historical.
- Run UI/static checks, shell syntax checks, all Node regression tests, and the package build before cutting a release.
- Build and inspect both IPK and APK outputs, with recorded SHA256 values.
- Keep native USB status and RF acceptance evidence separate in release notes.
- Keep the current AREDN package-manager deployment path compatible with APK
  while documenting IPK output for older images.
- Confirm generated packages contain the current UI, runtime modules, migration scripts, and generic Crow sysupgrade configuration.

The SudoRoom MeshCore reference page was reviewed as a side test. It publishes
MeshCore contact URLs for a repeater, room server, and companion device, but no
channel name/key pair. Adding those contacts is a separate Companion feature;
adding a channel requires the exact channel name, 16-byte PSK, and radio slot.
The operator procedure and this distinction are documented in `CHANNELS.md`.

### 6. GitHub issue cleanup — retired

Issue #1 about the custom firmware link is no longer an active Crow development task. The Crow backend uses the Companion binary API and does not require a firmware change for this implementation. Any firmware-specific compatibility question belongs in the hardware validation record.

## RF group-channel safety gate

The MeshCore TCP or USB backend may remain enabled. RF group receive and send
activate per channel only after the radio reports the exact same channel name,
key, and slot that Crow has configured. Channel discovery is authoritative for
the radio side; it must not silently join, persist, or enable an unmatched
channel.

### Gate 0: safe enabled baseline

Before a matching channel is configured:

```json
{
  "meshcore": { "enabled": true, "backend": "tcp" },
  "meshcore_tcp_api": {
    "enabled": true,
    "channel_discovery": true
  }
}
```

Expected behavior:

- the MeshCore transport may connect and discover the radio;
- no unmatched Crow-originated group send is attempted;
- no unmatched RF group receive is routed into Crow;
- direct traffic follows its separate identity and routing checks.

### Gate 1: negative software tests

With the backend test harness enabled but no exact local/radio match:

- an inbound group frame whose slot, name, or key differs is dropped before routing;
- an outbound group message without an exact verified slot/name/key tuple fails safely and increments the channel-send failure counter;
- a discovered radio channel that is absent from Crow remains runtime-only and does not modify Crow config;
- direct-message tests remain separate from group-channel tests.

### Gate 2: configure one matching group channel

Choose one radio group slot `N`. Configure that channel on the radio, then configure the exact same MeshCore channel name/key in Crow. Enable read-only discovery so Crow can verify the radio slot:

```json
{
  "channels": [
    { "namekey": "<exact-radio-channel-name-and-key>" }
  ],
  "meshcore_tcp_api": {
    "enabled": true,
    "channel_discovery": true
  }
}
```

When discovery reports slot `N` with the exact name/key, Crow maps that slot
to the local channel for receive and send. The radio remains the authority for
channel name, key, and slot. Crow must not invent a key or write the radio
configuration.

### Gate 3: positive RF receive

Send a test message over RF on slot `N` and verify:

- the Companion frame decodes with `group_slot: N`;
- Crow resolves `N` only when the discovered name/key is an exact local match;
- the message appears only in that channel;
- an otherwise identical message on an unmapped slot is dropped;
- no raw PSK appears in logs, telemetry, or UI.

### Gate 4: positive RF send

Send a Crow message to the mapped local channel and verify:

- `CMD_SEND_CHANNEL_MESSAGE (0x03)` is built for the verified slot `N`;
- the radio receives the message on the matching channel;
- `channel_sends_ok` increments;
- a Crow message targeting an unmapped channel does not produce an RF send and increments `channel_sends_failed` instead.

### RF gate acceptance

The software gate is complete when mismatched tuples are rejected and an
exact discovered tuple enables receive/send. Live RF work is complete only
when the positive receive/send tests pass after the radio and Crow are
configured. Until then, release notes must say **hardware validation pending**.

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

The canonical `.uc` tests must also be run with `ucode` available. If the
interpreter is unavailable on the target host, record that limitation rather
than treating the Node mirror as the native test.
