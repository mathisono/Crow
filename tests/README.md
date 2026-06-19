# Crow tests

Lightweight regression tests for Crow modules. No test framework dependency.

## Files

| File | Runtime | Purpose |
| --- | --- | --- |
| `test_outbound_formatter.uc` | `ucode` | Canonical tests for `lora_outbound_text.uc` (outbound LoRa text formatter: callsign + gateway tag + truncation). |
| `run_formatter_tests.js` | `node` | Node runner with a JS port of the formatter contract. Runs the same logical cases without needing a ucode interpreter, and auto-invokes the `.uc` tests when `ucode` is on PATH. |

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

## How to run

### From the repo root, with just Node (no OpenWrt SDK needed)

```sh
node tests/run_formatter_tests.js
```

This executes the JS port of the formatter against ~22 cases. If `ucode` is
on PATH, the same runner also invokes the `.uc` test file and reports its
result. Exits non-zero on any failure.

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

- Strict gatekeeper end-to-end decisions on outbound text.
- AREDN CGI path handling, WebSocket frame limits, UI escaping (covered by other static checks listed in `docs/CROW_MIGRATION_PLAN.md`).

If you add tests for any of the above, follow the same pattern: a canonical
`.uc` test plus a `node`-runnable mirror under `tests/` so CI / dev laptops
without `ucode` can still run them.
