# Crow tests

Lightweight regression tests for Crow modules. Core checks have no test framework
dependency; optional browser checks use Playwright and Chromium.

## Test entry point

Run the complete development suite from the repository root:

```sh
tests/run_all.sh
```

The runner executes every `tests/run_*.js` contract check. Runners with a
canonical ucode counterpart invoke it automatically when `ucode` is available;
the runner also executes the four standalone ucode suites. Tests and
development tools are not included in AREDN packages, and source-level test
hooks are stripped from release modules during packaging.

## Files

| File | Runtime | Purpose |
| --- | --- | --- |
| `run_aprs_backend_label_tests.js` | `node` | APRS backend display-name/callsign mapping. |
| `run_aprs_retry_dedupe_tests.js` | `node` | APRS retry IDs, bounded deduplication, and retained-history suppression. |
| `run_aredn_service_watch_tests.js` | `node` | Legacy and object-based AREDN watcher changes, empty reads, EOF recovery, and cleanup. |
| `run_backend_disconnect_ui_tests.js` | `node` | Backend-to-channel health mapping and compact disconnected overlay contracts. |
| `run_channel_export_tests.js` | `node` + optional `ucode` | Text/CSV channel export formatting, event routing, and browser download behavior. |
| `run_channel_join_tests.js` | `node` + optional `ucode` | Actual short/long join dispatch, shared keys, usage errors, and existing-channel preservation. |
| `run_channel_settings_ui_tests.js` | `node` + optional Playwright/Chromium | Empty/disconnected channel settings, reconnects, validation, and safe channel-list replacement. |
| `run_backend_setup_script_tests.js` | `node` + Python 3, Linux bubblewrap/BusyBox | Executes unchanged installer, upgrade, watchdog, USB-storage, bridge-loop and init scripts inside an isolated filesystem with mocked devices/services/package managers. |
| `run_storage_accounting_tests.js` | `node` + ucode | Runs exact storage source functions with inert I/O; verifies disk sectors, free-space bytes, numeric-string quotas and malformed output. Use `--emit` for an authorized native target. |
| `run_storage_persistence_tests.js` | `node` + optional ucode | Runs production storage/configuration functions and the startup merge against inert adapters; verifies restart persistence, unrelated-setting preservation, and write failures. Native filesystem checks use only a disposable local directory. |
| `run_formatter_tests.js` | `node` + optional `ucode` | Outbound LoRa callsign/tag formatting and truncation. |
| `run_meshcore_backend_selector.js` | `node` + optional `ucode` | Lazy backend selection and TCP/USB/UDP precedence. |
| `run_meshcore_serial_api_tests.js` | `node` + optional `ucode` | USB Companion framing, queue handling, and RF slot gate. |
| `run_meshcore_tcp_api_tests.js` | `node` + optional `ucode` | TCP accumulator fragmentation, bounds, resync, and direct-message parsing. |
| `run_meshtastic_api_tests.js` | `node` + optional `ucode` | Meshtastic API framing and channel behavior. |
| `run_router_gatekeeper_matrix.js` | `node` | Router/gatekeeper scope, local-direct handling, slot mapping, and callsign policy. |
| `run_storage_assimilate_tests.js` | `node` | Safe USB discovery, non-formatting assimilation, migration, quotas, and hotplug identity. |
| `run_serial_bridge_resolver_tests.js` | `node` | Stable MeshCore ACM identity selection, ambiguity refusal, and hotplug rescanning. |
| `run_ui_rendering_tests.js` | `node` + optional Playwright/Chromium | Real-DOM attribute escaping, channel controls, click dispatch, and inert message markup. |

Canonical ucode fixtures remain under `tests/test_*.uc`; the Node runners are
portable mirrors/static contract checks for development hosts without ucode.

## When to run

Run the formatter tests after **any** of the following:

- Editing `lora_outbound_text.uc` (logic, defaults, callsign fallback chain, truncation rules).
- Adding/renaming a transport that flows through `normTransport()` / `gatewayTag()`.
- Changing the default LoRa payload budget (`DEFAULT_LORA_MAX_PAYLOAD`) or the ellipsis marker.
- Changing how upstream callers populate `originating_callsign`, `callsign`, `from_callsign`, or `data.callsign` on outbound messages.
- Touching `meshcore.uc`, `meshtastic.uc`, `router.uc`, or the gatekeeper path in a way that could affect outbound text shape.
- Before opening a PR that touches any of the above.
- Before cutting an IPK/APK build for a release.
- As a quick smoke check after merging `main` if outbound text shape is in scope.

Also re-run if you update the test expectations themselves — keep the `.uc`
and `.js` cases in sync so both runtimes assert the same contract.

Run the router/gatekeeper matrix after touching `router.uc`, `gatekeeper.uc`,
MeshCore/Meshtastic backend message metadata, or local-channel mapping behavior.

## How to run

### From the repo root, with just Node (no OpenWrt SDK needed)

```sh
node tests/run_formatter_tests.js
```

This executes the JS port of the formatter against 20 cases. If `ucode` is
on PATH, the same runner also invokes the `.uc` test file and reports its
result. Exits non-zero on any failure.

To run all checks:

```sh
tests/run_all.sh
```

### With the ucode interpreter (canonical path on AREDN / OpenWrt SDK)

```sh
ucode -R -L .:./tests tests/test_outbound_formatter.uc
```

`-R` enables raw mode, `-L .:./tests` lets `import * as fmt from "lora_outbound_text"` resolve from the repo root. Exits non-zero on any failure.

### One-shot (whichever is available)

```sh
command -v ucode >/dev/null \
    && ucode -R -L .:./tests tests/test_outbound_formatter.uc \
    || node tests/run_formatter_tests.js
```

## What is covered

`gatewayTag()`:

- `meshcore` normalization to `MCGW` / `MCG{n+1}`.
- `meshtastic` mapping to `MTGW` / `MTG{n}`.
- Unknown transport falls back to `MCGW`.
- Null/zero gateway index handling.

`prepare()`:

- Null message guard returns `null`.
- Callsign fallback chain: `originating_callsign` → `callsign` → `from_callsign` → `data.callsign` → `"UNKNOWN"`.
- Missing `data.text_message` produces header-only output.
- Exact-fit at `max_payload` boundary.
- Truncation with `"..."` when remaining room `> 3`.
- Truncation without `"..."` when remaining room `<= 3`.
- Header-exceeds-budget hard truncation of the header itself.
- Default `max_payload` (255) when `null` is passed.

## What is not covered (yet)

- Live RF/TNC delivery and radio firmware behavior.
- AREDN CGI path handling and full live WebSocket integration.

Those require the live-node tools under `tools/`; they are deliberately kept
out of the deterministic local regression suite and out of release packages.

## Browser rendering regression checks

`run_ui_rendering_tests.js` uses real Chromium DOM parsing to check quoted
attributes, channel-list command replies, click dispatch, and inert chat markup.
It is included in `run_all.sh` and reports an explicit skip if Playwright is not
available. Install Playwright in your development environment, or point to an
existing installation and Chromium binary:

```sh
CROW_PLAYWRIGHT_MODULE=/path/to/playwright-core \
CROW_CHROMIUM=/path/to/chromium node tests/run_ui_rendering_tests.js
```

These tests use synthetic data, stub command dispatch, and never contact a node
or transmit radio traffic.

`run_channel_settings_ui_tests.js` uses the same Playwright variables. It loads
the real page, styles, and script, supplies a synthetic WebSocket, and blocks
all network requests. It checks the initial connection, empty-list creation,
preservation of existing channels, invalid forms, disconnects, and updated
server data while the editor is open.

## Fresh-install and backend setup testing

Follow [Fresh-install setup test](../docs/FRESH_INSTALL_SETUP_TEST.md) for the
live operator walkthrough. It requires a verified private backup and actual
UI access before resetting a node. An upgraded node with its old configuration
restored is not a passing fresh-install test.

`run_backend_setup_script_tests.js` executes the real shell scripts with
network isolation and private `/etc`, `/sys`, `/dev`, `/usr/local`, and `/tmp`.
Package managers, service commands, serial I/O, mounts, and formatting are
inert fixtures. It checks installer ordering, upgrade preservation, dependency
failure reporting, no-format assimilation, watchdog decisions, serial
re-enumeration, procd arguments, and the runner entry point. It reports an
explicit skip when Linux bubblewrap/BusyBox isolation is unavailable. A pass
does not certify a physical USB radio, a fresh installation, or RF delivery.

## Storage persistence regression

```sh
node tests/run_storage_persistence_tests.js
UCODE=/path/to/ucode node tests/run_storage_persistence_tests.js
```

The same behavioral fixture runs in both runtimes: already-mounted and newly
mounted assimilation/enable, disable, quota changes, base/override precedence,
local override paths, unrelated settings and null tombstones, UI saves after
activation, and failed open/short-write/flush/rename operations. Native checks
also exercise atomic replacement, UTF-8 byte counts, private permissions, and
temporary-file cleanup using real filesystem calls inside a disposable directory.

`--emit` prints the inert fixture for a separate native interpreter; it does not
mount media, install packages, change service configuration, or access a radio.
`CROW_SOURCE_ROOT=/path/to/older/source` runs the same regressions against old
production code, providing a negative control for the released-r1 persistence gap.

## Native join regression fixture

`run_channel_join_tests.js` exercises the actual command dispatcher and group
logic with inert dependencies. When `ucode` is installed it also runs
`test_channel_join.uc` against the same source. To prepare that canonical
fixture for a separate ucode host:

```sh
node tests/run_channel_join_tests.js --native-fixture /tmp/crow-join-fixture
ucode -L /tmp/crow-join-fixture /tmp/crow-join-fixture/test_channel_join.uc
```

The fixture captures events in memory; it does not read live Crow configuration,
save channels, start a service, or transmit messages. Copy only the generated
directory to a temporary test location if using another host, and remove it
after the check. The Node join and channel-settings runners accept
`CROW_SOURCE_ROOT` to verify regression failures against an older source tree.

If you add tests for any of the above, follow the same pattern: a canonical
`.uc` test plus a `node`-runnable mirror under `tests/` so CI / dev laptops
without `ucode` can still run them.
