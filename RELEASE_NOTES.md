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
