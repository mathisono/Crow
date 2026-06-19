# Crow migration/security patch plan

This repository is being migrated from Raven-compatible paths to native Crow paths while retaining limited one-time Raven import compatibility for existing installs.

Status updated: **2026-06-18**.

## Current direction

Crow should be Crow-first at runtime and packaging time:

- Runtime/config/service paths should prefer Crow names.
- Legacy Raven paths should be treated only as read-only compatibility/import sources.
- New writes should go to Crow paths.
- Sysupgrade config naming should be generic, not tied to a personal callsign.
- Raven config import must be schema-aware. Do not blindly copy whole old Raven config files into Crow if the Crow schema changes.
- Meshtastic should move to a direct TCP Port-API backend.
- MeshCore cleanup is planned but deferred; do not rework MeshCore in the current Meshtastic pass.

## Current status

| Area | Status | Notes |
| --- | --- | --- |
| AREDN image CGI path handling | **Implemented** | Image CGI path handling was hardened. Keep regression tests focused on traversal, absolute paths, and unexpected query values. |
| UI string/url rendering | **Temporary overlay implemented; direct merge pending** | `ui/ui-safe.js` currently provides safe rendering overrides and `ui/index.html` loads it after `ui.js`. The desired final state is to merge those helpers directly into `ui/ui.js`, remove overlay loading, and remove `ui-safe.js` from build packaging once verified. |
| WebSocket frame/message limits | **Implemented** | Frame/message/header size limits were added. Keep oversized-frame checks in validation. |
| Strict gatekeeper callsign normalization/config | **Implemented; hardware validation pending** | Callsign validation was tightened and default config documented. Final behavior still needs LoRa/MeshCore/Meshtastic hardware testing. |
| Crow runtime/config/service path migration | **Mostly implemented** | `config.uc` now prefers `/etc/crow.conf`, local `crow.conf`, and Crow override paths, with Raven read fallback. Package scripts are being moved to `/etc/init.d/crow` and `/usr/local/crow`. |
| Sysupgrade naming | **Updated target** | Use a generic sysupgrade config filename such as `crow.conf`. Do not use `KJ6DZB.crow.conf` or another personal callsign. |
| Raven-to-Crow import | **Schema-aware import required** | Import only compatible Raven keys into the current Crow default config. Do not blindly copy old Raven config wholesale. Runtime data directories can be copied only when Crow paths are missing. |
| Meshtastic backend | **Current focus** | Build a direct TCP Port-API backend to a Meshtastic ESP32 node, default port `4403`. See `docs/MESHTASTIC_TCP_PORT_API_BACKEND.md`. |
| MeshCore backend | **Deferred** | Keep current MeshCore functionality working. MeshCore can later be normalized behind the same backend boundary, but do not rewrite it during the Meshtastic TCP pass. See `docs/MESHCORE_TNC_BACKEND.md`. |
| Build packaging | **Needs validation** | Ensure packages include all required UI/runtime files and do not include stale overlay files once direct UI merge is complete. APK still depends on `mkapk.py` being available in PATH. |

## UI hardening plan

Current state:

- `ui/ui-safe.js` was added as a safety overlay.
- `ui/index.html` loads `ui.js` first and then `ui-safe.js`.
- `platforms/aredn/build.sh` currently packages the overlay so deployed UI gets the hardening.

Desired final state:

1. Merge safe rendering helpers directly into `ui/ui.js`:
   - `esc()` for HTML text.
   - `attr()` for attributes.
   - `safeClass()` for class tokens.
   - `safeInt()` for IDs/counts/onclick numeric arguments.
   - `safeUrl()` for URL allowlisting.
   - `linkifyEscaped()` for safe linkification.
2. Make `T(text)` null-safe and escaping.
3. Harden HTML-producing functions such as:
   - `htmlChannel()`
   - `htmlNode()`
   - `htmlNodeDetail()`
   - `htmlText()`
   - `htmlCommand()`
   - `backendOptions()`
   - `htmlChannelConfig()`
   - `htmlWinlinkMenu()`
   - `domWinlink()`
4. Ensure all external mesh/user/backend values are escaped or sanitized before entering visible HTML, attributes, classes, handlers, `href`, `src`, iframe `src`, or style values.
5. Add `rel="noopener noreferrer"` to `target="_blank"` links.
6. Remove `ui-safe.js` loading from `ui/index.html` after direct merge is verified.
7. Remove `ui-safe.js` from package inclusion after direct merge is verified.

Validation commands for the direct UI merge:

```sh
grep -n "innerHTML" ui/ui.js
grep -n "href=.*\${" ui/ui.js
grep -n "src=.*\${" ui/ui.js
grep -n "class=.*\${" ui/ui.js
grep -n "onclick=.*\${" ui/ui.js
grep -n "data-.*\${" ui/ui.js
grep -n "replace(.*<a" ui/ui.js
grep -n "target=\"_blank\"" ui/ui.js
node --check ui/ui.js
```

Hostile samples to use in fixture/manual tests:

```text
<img src=x onerror=alert(1)>
"><script>alert(1)</script>
javascript:alert(1)
data:text/html,<script>alert(1)</script>
native" onclick="alert(1)
test' onclick='alert(1)
bad<form><script>alert(1)</script>
```

## Config and migration plan

Crow config should be loaded in this order:

1. `/etc/crow.conf`
2. local `crow.conf` next to `SCRIPT_NAME`
3. `/etc/raven.conf` as legacy read fallback only
4. local `raven.conf` as legacy read fallback only

Crow override should be loaded in this order:

1. `/etc/crow.conf.override`
2. local `crow.conf.override`
3. `/etc/raven.conf.override` as legacy read fallback only
4. local `raven.conf.override` as legacy read fallback only

Runtime writes should go only to Crow override paths.

Raven import helper behavior:

- Use current Crow default config as the base.
- Read Raven config only if Crow config does not exist.
- Copy only known/stable compatible keys into the Crow config.
- Preserve Crow-owned defaults when Raven lacks a matching key.
- Never import unknown Raven keys blindly.
- Copy runtime data directories only when the Crow destination is missing.
- Preserve old Raven paths only as import sources, not as active Crow runtime paths.

## Meshtastic current plan

Meshtastic should become a direct TCP Port-API backend:

```json
{
  "meshtastic": {
    "enabled": true,
    "transport": "tcp",
    "host": "192.168.4.1",
    "port": 4403
  }
}
```

Rules:

- TCP only; do not implement serial support.
- Default Port-API TCP port is `4403`.
- Open and maintain a persistent TCP stream to the ESP32 Meshtastic node.
- Decode streamed Port-API protobuf frames into Crow's normalized message shape.
- Send Crow-originated text through the same TCP Port-API connection.
- Handle reconnect/backoff without blocking the main event loop.
- Drop unsupported/encrypted payloads unless Crow can safely identify and route them.
- Preserve strict-gatekeeper checks before bridged messages are queued or forwarded.

See `docs/MESHTASTIC_TCP_PORT_API_BACKEND.md` for the focused implementation plan.

## MeshCore current plan

MeshCore is not the current implementation focus.

- Keep existing MeshCore behavior working.
- Do not mix MeshCore parsing into Meshtastic code.
- Do not rewrite MeshCore during the Meshtastic TCP Port-API pass.
- Plan for MeshCore to later expose the same Crow-facing backend shape:
  - `setup(config)`
  - `tick()`
  - `recv()`
  - `send(msg)`
  - `shutdown()`

## Build/test notes

Available local checks:

```sh
# Static/syntax checks
node --check ui/ui.js
sh -n platforms/aredn/build.sh platforms/aredn/admin.sh platforms/aredn/usb-setup.sh platforms/aredn/postinst platforms/aredn/postinstall platforms/aredn/postupgrade platforms/aredn/prerm

# Outbound LoRa text formatter regression tests, if present
node tests/run_formatter_tests.js
ucode -R -L .:./tests tests/test_outbound_formatter.uc

# Package build
./platforms/aredn/build.sh
```

Observed build environment issue:

- `platforms/aredn/build.sh` requires `mkapk.py` to produce `.apk` artifacts.
- `mkapk.py` is from `kn6plv/MakeAPK`.
- If `mkapk.py` is missing, IPK may still build but APK output will fail.

## Remaining validation before production confidence

1. Merge UI escaping directly into `ui/ui.js`, then remove overlay loading and packaging.
2. Re-run UI escaping static/fixture checks after the direct merge.
3. Confirm package build includes all required Crow UI/runtime files.
4. Confirm sysupgrade config installs as generic `crow.conf`.
5. Confirm install/upgrade/remove scripts use `/etc/init.d/crow` and Crow paths.
6. Confirm Raven-to-Crow import on a test node with legacy Raven config/state present.
7. Confirm schema-aware Raven import does not break when Crow config structure changes.
8. Test strict gatekeeper behavior with real Meshtastic/MeshCore/LoRa traffic.
9. Implement and test Meshtastic TCP Port-API backend.
10. Defer MeshCore rewrite until Meshtastic direct backend is stable.

## Historical planned patch set

Original set:

1. Harden AREDN image CGI path handling.
2. Harden UI string/url rendering.
3. Add WebSocket frame/message limits.
4. Tighten strict-gatekeeper callsign normalization and document config.
5. Move Crow runtime/config/service paths to Crow names, with first-install import from legacy Raven locations.

Current added planning items:

6. Replace overlay UI hardening with direct `ui.js` hardening.
7. Use generic sysupgrade config naming.
8. Make Raven import schema-aware.
9. Implement Meshtastic direct TCP Port-API backend.
10. Keep MeshCore work planned but deferred.
