# Crow migration/security patch plan

This repository is being migrated from Raven-compatible paths to native Crow paths while retaining one-time Raven import compatibility for existing installs.

Status updated: **2026-06-16**.

## Current status

The migration/security patch set has moved from planning into implementation. Recent work covered the original five migration items plus follow-up validation and build-environment notes.

| Area | Status | Notes |
| --- | --- | --- |
| AREDN image CGI path handling | **Implemented upstream** | Image CGI path handling was hardened in the Crow migration patch series. Keep regression tests focused on traversal, absolute paths, and unexpected query values. |
| UI string/url rendering | **Implemented and validated locally** | The temporary `ui/ui-safe.js` hardening was merged directly into `ui/ui.js`. `ui-safe.js` is no longer needed once this renderer is deployed. |
| WebSocket frame/message limits | **Implemented upstream** | Frame/message size limits were added in the migration patch series. Keep oversized-frame checks in future validation. |
| Strict gatekeeper callsign normalization/config | **Implemented/documented upstream; hardware validation pending** | Callsign validation was tightened and default config documented. Final behavior still needs LoRa/MeshCore hardware testing. |
| Crow runtime/config/service path migration | **Implemented upstream** | Runtime/config/service paths moved toward Crow names with Raven fallback/import compatibility. Postinstall/postupgrade/remove scripts were updated to use Crow service behavior. |
| MeshCore TNC backend | **Draft, not production activated** | See `docs/MESHCORE_TNC_BACKEND.md`. The legacy `meshcore.uc` UDP/multicast backend remains untouched. Live TNC/KISS compatibility testing is pending hardware. |
| Build packaging | **IPK path works; APK needs `mkapk.py` in PATH** | `mkapk.py` comes from `https://github.com/kn6plv/MakeAPK`. It was installed on MSE-88 at `/home/mat/.local/bin/mkapk.py` for future builds. |

## UI hardening details

Recent local validation merged the safe rendering layer into the main renderer:

- Added helpers near `T()` in `ui/ui.js`:
  - `esc()` for HTML text escaping.
  - `attr()` for attribute escaping, including single quotes and backticks.
  - `safeClass()` for class-token allowlisting.
  - `safeInt()` for numeric IDs/counts/onclick arguments.
  - `safeUrl()` for allowing only `http:` and `https:` URLs; rejected URLs render as `#`.
  - `linkifyEscaped()` for URL linkification after message text has already been escaped.
- Audited renderer functions including channels, nodes, node detail, messages, commands, channel config, Winlink menu, and Winlink iframe wrapper.
- Added `rel="noopener noreferrer"` to every `target="_blank"` link.
- Replaced direct `data-namekey` selector interpolation with dataset matching where needed.
- Confirmed hostile values cannot break out of HTML, attributes, classes, inline handler arguments, or URL attributes.

Validation commands used during the UI hardening pass included:

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

A temporary Node-based renderer fixture was also used with hostile samples such as:

```text
<img src=x onerror=alert(1)>
"><script>alert(1)</script>
javascript:alert(1)
data:text/html,<script>alert(1)</script>
native" onclick="alert(1)
test' onclick='alert(1)
bad<form><script>alert(1)</script>
```

The fixture exercised:

- `htmlChannel()`
- `htmlNode()`
- `htmlNodeDetail()`
- `htmlText()`
- `htmlCommand()`
- `htmlChannelConfig()`
- `htmlWinlinkMenu()`

Normal examples were also checked: normal channel, normal node, message with `http://` URL, structured image with `https://` URL, and Winlink menu item.

## Build/test notes

The repository does not currently include a package.json, Makefile test target, or formal JS test framework. Available local checks are mostly syntax/static/build checks:

```sh
node --check ui/ui.js
sh -n platforms/aredn/build.sh platforms/aredn/admin.sh platforms/aredn/usb-setup.sh
./platforms/aredn/build.sh
```

Observed build environment issue:

- `platforms/aredn/build.sh` requires `mkapk.py` to produce `.apk` artifacts.
- `mkapk.py` is not part of Crow/Raven; it is in `kn6plv/MakeAPK`.
- MSE-88 now has `mkapk.py` installed in `/home/mat/.local/bin`, which is on that user's PATH.
- On Python 3.8 systems, the installed copy needed `from __future__ import annotations` for newer type annotation syntax.

## Remaining validation before production confidence

1. Re-run full package build on MSE-88 now that `mkapk.py` is installed.
2. Re-run UI escaping smoke/static checks after any future renderer change.
3. Test strict gatekeeper behavior with real LoRa traffic once hardware arrives.
4. Test MeshCore TNC/KISS backend with real MeshCore hardware before activating it in production.
5. Confirm Raven-to-Crow first-install import behavior on a test node with legacy Raven config/state present.
6. Confirm upgrade/remove scripts use Crow service names and leave no unexpected Raven runtime writes except documented fallback/import paths.

## Historical planned patch set

Original planned set, now mostly implemented:

1. Harden AREDN image CGI path handling.
2. Harden UI string/url rendering.
3. Add WebSocket frame/message size limits.
4. Tighten strict-gatekeeper callsign normalization and document config.
5. Move Crow runtime/config/service paths to Crow names, with first-install import from legacy Raven locations.
