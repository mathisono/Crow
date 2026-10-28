# Fresh-install qualification: BB5, 2026-10-28

Tested the **published Crow 0.0.3-r0 APK** on AREDN
`20261024-26fe06b0` (RouterBOARD 912UAG-5HPnD). The package was removed and
installed fresh after verified, stopped-service backups. Old Crow/Raven
configuration and application data were quarantined so migration could not
repopulate the test. No radio firmware, channel slots, or USB filesystem was reset.

## Outcome

- The live managed browser loaded all three factory channels, including AREDN
  without an enabled radio backend.
- Six operator channels were reconstructed using the channel UI, `/join`, and
  `/channels join`; backend connections and unsupported advanced fields were
  entered individually over SSH. No saved configuration was restored.
- Effective base-plus-override configuration matched the reference exactly.
  All six active channels' message limits, notification, image and Winlink
  settings also matched (absent/null and false are equivalent for disabled flags).
- USB serial identity selection, sole `socat` ownership, init enablement, live
  mass-storage helper execution, Companion self-info, and APRS-IS connection
  were checked. A bridge restart caused a new handshake without restarting Crow.
- Crow restarts and a subsequent UI save preserved the recreated settings,
  after the explicit storage-mode workaround below.
- Original history and private identity files remain in protected, verified
  recovery storage. Active application data started fresh; historical messages
  or identity files were **not imported** as a shortcut to setting up preferences.

This is a successful reconstruction **with documented workarounds**, not a
claim that every first-run path in 0.0.3-r0 is defect-free. There was no node
reboot, physical USB unplug/replug, intentional RF test transmission, public chat
test message, or room login. Software reconnect/handshake success is not RF proof.

## Findings and release distinction

| Finding | Live effect / workaround | Source status |
| --- | --- | --- |
| Channel editor limits typed names to 11 characters | A 12-character existing name was truncated. Discard the draft; use `/channels join` and edit its preferences in the UI. | Limit raised to 32; real browser typing regression fails before and passes after. |
| USB activation does not persist Crow's storage mode | `/storage assimilate` succeeded, but restart returned to internal storage. Explicitly set `storage.mode` and device in the persistent configuration. | Recorded; automatic persistence is not fixed in this change. |
| Storage size/free-space strings use `+ 0` | ucode concatenates a zero, producing 10× capacity/free-space values. Use `df -k` to check actual capacity; the low-space guard is affected too. | Explicit numeric conversion; five native exact-function tests pass, including the free-space guard input. |
| Optional runner executes `router.uc` | The router module is not the application entry point. Use the normal init service. | Runner corrected and tested; normal init already used `crow.uc`. |
| No backend setup wizard or label editor | Use explicit SSH fields for transport, credentials, slot map, labels and advanced group options. | Guides now describe actual supported surfaces. |
| Room-add command has whitespace-only tokenization | Add with a single-word alias, then edit the saved display name if spaces are required. Do not log in during a setup-only test. | Documented limitation. |
| Watchdog observed a stale pre-install heartbeat during startup | One restart occurred before the fresh UI became ready. `status=running` alone is not application readiness; wait for channels and handshakes. | Observation recorded; healthy watchdog and isolated recovery cases pass. |

The installed/published **0.0.3-r0 payload was not patched** during this test.
The runner, channel-name, and accounting corrections are included in
**0.0.3-r1**; they are not present in the older 0.0.3-r0 release packages.
The automatic USB storage-mode persistence gap remains unresolved. Publishing
a new release does not update an installed node, and this historical live
test does not constitute a fresh-install qualification of 0.0.3-r1.

## Reproduce

Follow [Fresh-install setup test](FRESH_INSTALL_SETUP_TEST.md) and
[USB MeshCore setup](USB_MESHCORE_SETUP.md). Keep keys, passcodes, room passwords,
historical messages, and node identity files out of shared evidence.

The script runner executes 20 isolated setup/backend cases. Channel-settings
and rendering fixtures provide 24 browser checks. The native accounting runner
uses exact source functions with inert I/O:

```sh
node tests/run_backend_setup_script_tests.js
node tests/run_channel_settings_ui_tests.js
node tests/run_storage_accounting_tests.js
```

Without local ucode, the accounting runner reports a skip. Its `--emit` output
can be executed with `ucode -` on an authorized target; it does not mount,
format, install packages, modify live configuration, or access the radio.
