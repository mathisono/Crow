# Crow v0.0.2-r20389266 — pre-release candidate

Commit: `421aa78`
Status: **hardware validation pending**

This candidate contains the first committed MeshCore Companion TCP and USB
serial backend implementation. RF group receive/send remains intentionally
gated until an exact group channel is configured in both Crow and the radio.
See [DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md).

## New in this candidate

- MeshCore Companion TCP backend with bounded message-waiting queue drain.
- MeshCore Companion USB serial backend using the same binary protocol.
- Direct and channel receive for legacy and v3 response formats.
- Direct replies using learned MeshCore public-key prefixes.
- Channel discovery, runtime notifications, telemetry, and backpressure.
- Backend selection tests and direct-identity regression coverage.
- Vendored APK builder support for current AREDN packaging.

## Validation

- 104 Node regression tests passed.
- UI and shell syntax checks passed.
- IPK/APK package build passed.
- Canonical `ucode` tests were not run on the build host because `ucode` is not installed.
- Live MeshCore TCP/USB and RF validation is pending hardware access/configuration.

## Candidate artifacts

```text
a3b5a997d47a12a0456c424312a26a34b3577116aa6fd616cf6d3b941389caa7  crow_alpha.ipk
113274efa9a9ea49ec8ad355bc694d8edbe1780cd5ebf5b054016fc7786ce76a  crow-alpha.apk
```

---

# Crow v0.0.2-r20118884

## Highlights

- MeshCore TCP Companion backend improvements.
- Direct message receive creates `DirectMessages <sender-id>` threads.
- Direct message send uses a learned MeshCore public-key prefix.
- MeshCore channel send supports public and mapped channels.
- v1/v3 MeshCore direct/channel parser improvements.
- `0x88` MeshCore logData frames are counted and rate-limited.
- Strict Gatekeeper requires the sender callsign in the message text body.
- Backend telemetry includes direct sends, channel sends, parser counters, discovery, and backpressure.
- APK build support is included for newer AREDN stable releases.

## Artifacts

- `crow_alpha.ipk` for older opkg-based AREDN/OpenWrt nodes.
- `crow-alpha.apk` for newer apk-based AREDN/OpenWrt nodes.

## Install

For apk-based nodes:

```sh
apk add --allow-untrusted /tmp/crow-alpha.apk
/etc/init.d/crow restart
```

For opkg-based nodes:

```sh
opkg install /tmp/crow_alpha.ipk || opkg install --force-reinstall /tmp/crow_alpha.ipk
/etc/init.d/crow restart
```

## SHA256

```text
93c72d7b45a674fba8e509ca4ad87572eefb93f5147862704921842e869fd218  crow_alpha.ipk
5cc3f5fc6c184c577e6bb8ba4463606ebc6d6a0f76f2e8239fc94df4fb07e5c3  crow-alpha.apk
```
