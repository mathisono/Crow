# Crow v0.0.2-r20525998 — release candidate

Status: **release candidate; selected hardware gates remain open**

This candidate contains the release-hardening pass for the MeshCore Companion
TCP and USB serial backends. RF group receive/send activates only when radio
discovery verifies an exact channel name/key/slot match with Crow.

The supervised BB5MC TCP/bridge path and fresh GUI-to-GUI tests are proven in
both directions. One tagged A2B air message was observed through Crow. The
reverse tagged air direction, native direct USB receive, and Meshtastic TCP
hardware validation remain separate open gates; this note does not claim them
proven.
See [DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md).

## New in this candidate

- MeshCore Companion TCP backend with bounded message-waiting queue drain.
- MeshCore Companion USB serial backend using the same binary protocol.
- Direct and channel receive for legacy and v3 response formats.
- Direct replies using learned MeshCore public-key prefixes.
- Channel discovery, runtime notifications, telemetry, and backpressure.
- Exact-match RF group receive/send gate with negative key/slot coverage.
- Bounded opt-in `0x1B` channel-datagram text routing for both transports.
- Compatibility/strict policy for modern direct frames without a destination ID.
- Meshtastic discovery notification parity without persistence or raw PSK output.
- Backend selection, direct identity, parser, and target-`ucode` regression coverage.
- Reproducible IPK/APK builds with `SOURCE_DATE_EPOCH` support.
- Vendored APK builder support for current AREDN packaging.

## Validation

- 209 Node regression tests passed.
- 133 canonical `.uc` checks passed on BB5MC's AREDN `ucode` runtime.
- UI and shell syntax checks passed.
- IPK/APK package build and package-content inspection passed.
- Fixed-epoch rebuilds produced identical IPK/APK bytes.
- Native direct USB was tested and safely reverted to the proven supervised
  bridge configuration after no self-info/RF frame was observed through Crow.

## Candidate artifacts

```text
a1887274d2f5ba5c8b1db571c64b6cc35303596482897d8e1cfe3eb6b26d6b10  crow_alpha.ipk
878d25e87f6aa977f089634062a0944231682b36bcdc8e23d146ec48de242ef7  crow-alpha.apk
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
