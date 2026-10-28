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
| USB activation does not persist Crow's storage mode | In older 0.0.3-r0/r1, explicitly set `storage.mode` and device in the persistent configuration; runtime activation alone is insufficient. | Fixed in 0.0.3-r2: activation, disable, and quota commands persist through the configuration writer. BB5 command/restart checks and portable/native failed-write regressions pass. |
| Storage size/free-space strings use `+ 0` | ucode concatenates a zero, producing 10× capacity/free-space values. Use `df -k` to check actual capacity; the low-space guard is affected too. | Explicit numeric conversion; five native exact-function tests pass, including the free-space guard input. |
| Optional runner executes `router.uc` | The router module is not the application entry point. Use the normal init service. | Runner corrected and tested; normal init already used `crow.uc`. |
| No backend setup wizard or label editor | Use explicit SSH fields for transport, credentials, slot map, labels and advanced group options. | Guides now describe actual supported surfaces. |
| Room-add command has whitespace-only tokenization | Add with a single-word alias, then edit the saved display name if spaces are required. Do not log in during a setup-only test. | Documented limitation. |
| Watchdog observed a stale pre-install heartbeat during startup | One restart occurred before the fresh UI became ready. `status=running` alone is not application readiness; wait for channels and handshakes. | Observation recorded; healthy watchdog and isolated recovery cases pass. |

The installed/published **0.0.3-r0 payload was not patched** during this test.
The runner, channel-name, and accounting corrections are included in
**0.0.3-r1**; they are not present in the older 0.0.3-r0 release packages.
The automatic USB storage-mode persistence gap is fixed in **0.0.3-r2**, not
in r0/r1. The separate upgrade qualification below validates the r2 candidate;
it does not retroactively change the historical fresh-install results.

## Follow-up: 0.0.3-r2 upgrade and storage-persistence qualification

After verified private backups, BB5 was upgraded from 0.0.3-r0 to the r2 APK
candidate on the same AREDN firmware. All 86 installed release files matched
the candidate package. Live commands exercised:

- `/storage usb disable`, followed by a Crow restart: internal mode persisted
  even while the USB filesystem remained mounted.
- `/storage assimilate`, followed by a restart: USB mode/device persisted
  without manually editing the configuration.
- An increased image quota, restart, and restoration of the original quota
  through `/storage quota images`: the intended saved values persisted.
- Disable then `/storage usb enable`, followed by a restart: USB mode returned
  and the original effective configuration matched exactly.

The final UI reported 0.0.3-r2, six channels, active USB storage, and no page
errors. APRS-IS connected and the USB Companion TCP backend completed a current
self-info handshake. Six channel preferences, all 75 baseline messages, active
node ID/keys, and the protected recovery files were preserved. Node-location
fields refreshed normally and are not treated as identity-key changes.

An earlier, unpublished r2 candidate exposed a second bug during the fully
restarted disable/enable cycle: clean message caches were not checkpointed to
the new storage root, so older internal preferences/history could return.
The affected active data was recovered from the verified pre-test backup, and
the correction now checkpoints loaded message/text-store state and identity on
root changes. Five additional portable/native regressions reproduce that gap
before the fix and cover both directions, startup/no-op selection, and fallback.
The final live qualification was repeated against the corrected package.

This was an **upgrade and storage-persistence test**, not another fresh install.
The live drive was already mounted; new-mount and failed-write cases were tested
with inert native fixtures. No node reboot, physical USB unplug/replug, formatting,
intentional RF test transmission, or history reimport was performed. See the
[r2 release](https://github.com/mathisono/Crow/releases/tag/v0.0.3-r2) attachment
`VALIDATION.md` for package checksums, source identity, and complete scope.

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
node tests/run_storage_persistence_tests.js
```

Without local ucode, the accounting runner reports a skip. Its `--emit` output
can be executed with `ucode -` on an authorized target; it does not mount,
format, install packages, modify live configuration, or access the radio.

The persistence runner uses the actual storage functions, configuration writer,
and startup merge with inert I/O. It repeats its behavioral cases in ucode when
available, and verifies the real native filesystem API only in a disposable
local directory. Use `UCODE=/path/to/ucode` to select a development interpreter.
Its `--emit` output contains only the inert behavioral fixture.
