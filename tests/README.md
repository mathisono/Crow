# Crow tests

Lightweight regression tests for Crow modules. No test framework dependency.

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
| `run_backend_disconnect_ui_tests.js` | `node` | Backend-to-channel health mapping and compact disconnected overlay contracts. |
| `run_formatter_tests.js` | `node` + optional `ucode` | Outbound LoRa callsign/tag formatting and truncation. |
| `run_meshcore_backend_selector.js` | `node` + optional `ucode` | Lazy backend selection and TCP/USB/UDP precedence. |
| `run_meshcore_serial_api_tests.js` | `node` + optional `ucode` | USB Companion framing, queue handling, and RF slot gate. |
| `run_meshcore_tcp_api_tests.js` | `node` + optional `ucode` | TCP accumulator fragmentation, bounds, resync, and direct-message parsing. |
| `run_meshtastic_api_tests.js` | `node` + optional `ucode` | Meshtastic API framing and channel behavior. |
| `run_router_gatekeeper_matrix.js` | `node` | Router/gatekeeper scope, local-direct handling, slot mapping, and callsign policy. |
| `run_storage_assimilate_tests.js` | `node` | Safe USB discovery, non-formatting assimilation, migration, quotas, and hotplug identity. |
| `run_serial_bridge_resolver_tests.js` | `node` | Stable MeshCore ACM identity selection, ambiguity refusal, and hotplug rescanning. |

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
- AREDN CGI path handling, browser rendering, and full WebSocket integration.

Those require the live-node tools under `tools/`; they are deliberately kept
out of the deterministic local regression suite and out of release packages.

If you add tests for any of the above, follow the same pattern: a canonical
`.uc` test plus a `node`-runnable mirror under `tests/` so CI / dev laptops
without `ucode` can still run them.
