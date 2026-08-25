# MeshCore Companion TCP Validation Report — 2026-07-06

Status: **historical hardware validation report; not validation of current HEAD**.

The report below covers the 2026-07-06 build listed in its Build tested
section. Use `DEVELOPMENT_PLAN.md` for the current validation gates and do not
use this document as evidence that commit `421aa78` has passed live RF tests.

This report records the validation run performed from MSE-88 against Hub5 and the MeshCore Companion TCP device.

## Build tested

```text
Commit tested: 55a35f258ac9708e160045121a6f0de2ecd18cf4
Package: crow_0.0.2-r16053209_all.ipk
Package path: platforms/aredn/crow_alpha.ipk
Package size: 288K
SHA256: 89f55f3bc2d6c2cdf7b642b51154bdfb212266dff50d29b225b54c08ad516ef0
```

Patch commits included in the tested build:

```text
3841a9b Validate Companion framing and expose TCP backend telemetry
55a35f2 Fix ucode runtime compatibility for TCP backend routing
```

## Nodes

```text
10.245.94.33     deployed, installed, restarted, Crow running
10.188.138.222   not deployed, SSH timed out on port 2222
```

MeshCore device:

```text
10.245.94.47:4403
```

## Framed Companion validation

Result: **PASS**.

The validation script sent the full framed Companion command:

```text
3c0c00010000000000000043726f77
```

The device accepted the TCP connection on port `4403` and returned a radio-to-client frame:

```text
marker: 0x3e
response code: 0x05
```

This verifies that the test script is now using the same framed command structure as Crow's `meshcore_tcp_api.uc` backend.

## Crow TCP backend startup

Result: **PASS**.

Observed log patterns:

```text
meshcore_backend: selected tcp backend
meshcore_tcp_api: connected tcp companion ...
meshcore_tcp_api: handshake sent (CMD_APP_START) frame_bytes=15 sent=15
```

No crash loop was observed after the runtime compatibility patch.

## Router scope and Strict Gatekeeper

Static checks: **PASS**.

Runtime behavior matrix: **not fully exercised**.

The previous runtime crash from router code was patched and did not reappear after deployment.

Still needs manual/fixture validation:

- unknown Meshtastic channel drop;
- unknown MeshCore group slot drop;
- UDP direct frame not addressed to Crow drop;
- TCP API local-direct accept;
- Strict Gatekeeper callsign pass/drop behavior;
- per-channel ACL allow/deny behavior.

## Telemetry

Installed modules expose the requested fields:

```text
message_waiting
sync_requests
sync_backpressure
no_more_messages
pending_rx
max_pending_rx
channel_discovery_requests
channel_info_responses
channels_discovered
channels_updated
Meshtastic API status fields
```

UI `/backends` confirms backend state, but does not currently render all counters.

## Drain test

Optional `--drain-on-83` test timed out after `0x05` because no `0x83` message-waiting push arrived during the test window.

This is not a failure of queue draining. It means no queued MeshCore radio message was available to trigger the push/poll path during that run.

## Failures / incomplete items

```text
- Local main is diverged from origin/main: ahead 7, behind 51.
- mkapk.py is missing, so no APK was produced.
- Local host cannot reach MeshCore TCP directly; MSE-88 can.
- 10.188.138.222 SSH timed out on port 2222.
- MeshCore self-info parsing produces a garbled device name.
```

## Next recommended fixes

### 1. Fix MeshCore RESP_SELF_INFO device-name parsing

Current parser scans for the first printable byte starting immediately after the 32-byte public key. That can accidentally pick up printable bytes from hardware hash / MAC / role fields and produce a garbled prefix.

Recommended patch:

```text
- Treat RESP_SELF_INFO fixed header as:
  byte 0       response code 0x05
  bytes 1-32   public key
  bytes 33-34  MAC / hardware hash or reserved
  byte 35      role/type
  bytes 36+    node name
- Start normal name extraction at byte 36.
- Trim trailing NULs.
- If byte 36 is not printable, then fall back to the current scan behavior.
```

### 2. Reconcile branch divergence

Local `main` cannot fast-forward because it is ahead and behind `origin/main`. Decide whether to merge/rebase or move the tested branch to a named validation branch.

### 3. Restore APK build

Install or restore `mkapk.py` so both artifacts are produced:

```text
crow_alpha.ipk
crow-alpha.apk
```

### 4. Complete runtime behavior matrix

Run router scope and Strict Gatekeeper behavior tests with generated fixtures or live messages.

### 5. Improve UI telemetry

Backend status exposes the counters, but `/backends` does not render all telemetry fields yet. Add UI rendering if operators need live visibility.
