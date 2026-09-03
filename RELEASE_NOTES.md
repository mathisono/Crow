# Crow v0.0.2-r21140793

This release hardens Crow for constrained AREDN nodes and rolls the completed
MeshCore Companion, APRS, watchdog, and USB-storage work into one tested build.

## Highlights

- Lazy-loads only the configured MeshCore and Meshtastic transports, including
  explicit Meshtastic protobuf registration and optional TCP discovery.
- Adds Crow heartbeat monitoring and a procd watchdog for automatic recovery.
- Suppresses APRS retries with bounded de-duplication, deterministic cross-node
  message IDs, and clearer backend/callsign labels.
- Adds non-destructive `/storage assimilate`, UUID/label persistence, hotplug
  remount recovery, and bounded degraded-mode image storage.
- Hardens MeshCore TCP and USB Companion framing, queue drain, direct identity,
  channel-data bounds, private-channel provisioning, and room-server login.
- Requires an exact configured channel name/key/slot tuple before MeshCore group
  receive or transmit is authorized.
- Preserves live Crow configuration across APK upgrades and marks it as an IPK
  conffile for opkg-based systems.
- Retains the historical package builds and MeshCore soak output used during
  development in the Git repository for audit history.

## Validation

- 268 Node regression checks passed across ten suites.
- 240 canonical `.uc` checks passed on BB5MC's AREDN ucode runtime.
- Python compilation, shell syntax, and both Go helper builds passed.
- Fixed-epoch rebuilds produced byte-identical IPK and APK artifacts.
- Package inspection confirmed test hooks are stripped, the MIPS raw-TTY helper
  is static, all seven lazy-loader modules compile, and IPK conffile metadata is
  present.
- Live APK upgrades passed on Hub5 and BB5MC with configuration checksums
  unchanged. Crow, the watchdog, HTTP UI, and APRS/Xastir connections recovered
  on both nodes.

The previously documented limits still apply: a connected Companion endpoint
that closes without returning frames is not RF proof, and the retained soak
files include historical failure evidence as well as successful short runs.
See [DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md) for the hardware gate record.

## Artifacts

- `crow_alpha.ipk` for opkg-based AREDN/OpenWrt nodes.
- `crow-alpha.apk` for apk-based AREDN/OpenWrt nodes.

The bundled `crow-rawtty` fallback is built for MIPS32, matching the tested
BB5MC USB/serial target. Other architectures can use `stty` when available or
rebuild with the matching `CROW_GOARCH` settings documented in the repository.

## Install

For apk-based nodes:

```sh
apk add --allow-untrusted /tmp/crow-alpha.apk
```

For opkg-based nodes:

```sh
opkg install /tmp/crow_alpha.ipk || opkg install --force-reinstall /tmp/crow_alpha.ipk
```

## SHA256

```text
1e7869edf9e39f4a9a33749bd4e3d84b00cb83c7f6759b45a3e251ec5911ada2  crow_alpha.ipk
892a560b25d023344ab7c0327dd5a53da6fa470db255a64b252446bc5e3fb2e4  crow-alpha.apk
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
