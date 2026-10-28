# Fresh-install operator setup test

## Goal and pass criteria

Install a released Crow package with fresh application configuration, then
recreate an operator's backed-up settings using the UI and supported slash/SSH
commands. **Do not upload, restore, or copy the saved configuration into the
new installation.** The backup is the reference and emergency recovery path.

A passing run requires live UI interaction, supported commands, effective
configuration parity, backend readiness, and persistence after a Crow restart.
Source inspection, mock tests, an upgrade preserving old settings, or a copied
configuration alone do not satisfy the test.

See [BB5 qualification findings](FRESH_INSTALL_FINDINGS.md) for a completed
0.0.3-r0 run, confirmed defects, workarounds and verification limits.

## Preconditions and recovery

- Record the exact release asset, SHA256, source commit, node hardware, firmware,
  package manager, and before/after service identities.
- Back up and verify the active base and override files, current installation,
  init/bridge scripts, enable links, USB mount/hotplug settings, and app data.
  Keep the archives private (directory mode 0700, files 0600), including keys,
  passcodes, room credentials, and message history. Never commit them.
- Confirm live UI navigation and user input work **before** stopping services or
  moving configuration. A browser-policy/access failure blocks the live reset;
  do not substitute a lower-level WebSocket API test and call it a UI pass.
- Stop the watchdog before intentionally stopping Crow. Prevent legacy Raven
  files or existing Crow overrides/data from silently repopulating a fresh setup.
  Move them into verified recovery storage; do not discard them.
- Preserve radio firmware/slots and the USB filesystem. Do not format a data
  drive or send public chat merely to test setup.
- Document emergency rollback separately. If rollback is needed, restore the
  working configuration to recover service and mark fresh setup incomplete.

## Reference-to-input worksheet

Read the private backup locally and record desired logical values without
printing secrets into the report. Do not treat matching JSON formatting as parity.

| Setting | Operator input path | Required check |
| --- | --- | --- |
| Default AREDN/preset channels | Fresh package startup | AREDN present without a LoRa radio; presets do not imply radio connectivity. |
| Additional channel names/keys | Channel settings and `/join` or `/channels join` | Correct tuple; no duplicates or loss of existing channels. |
| Channel backend binding | Channel settings after backend configuration | TCP bridge vs native USB binding correct. |
| Per-channel message limits, badges, images, Winlink | Channel settings | Saved values survive page reconnect and service restart. |
| Custom channel labels | SSH configuration (no label editor in current UI) | Exact labels retained after later UI saves. |
| Radio host/port/device, handshake profile and slot mappings | SSH configuration | Exact reference values; current self-info received. |
| USB bridge dependencies and startup | Package-manager and init commands | Correct driver, single device owner, loopback listener, enabled service. |
| APRS identity, server, credentials and TX policy | SSH configuration | Correct backend and intended policy, no test message sent. |
| APRS group/member list | `/join %Group backend=NAME CALL1 CALL2` without message text | Members and binding correct; advanced repeat/rate options checked separately. |
| Room-server records | Supported room-add command or SSH for advanced values | Exact names, keys and credentials; login/transmission is a separate action. |
| USB message storage | `/storage usb scan`, `/storage assimilate`, `/storage status` plus persistence check | Existing media retained; same mount/quotas; Crow storage mode survives restart. |
| Callsign/debug/UI preferences | SSH configuration where not exposed | Desired effective value, including platform-derived overrides. |

The current UI does not provide a general backend wizard. Document each needed
SSH edit as an operator step rather than silently bulk-generating a saved config.
Likewise, do not assume a runtime storage command persists Crow's configuration:
check the saved `storage.mode` and recheck after restarting.

## Live procedure

1. **Back up and baseline.** Verify archives and build the worksheet. Record
   enabled services, serial device identity/ownership, storage mount, and redacted
   channel/backend state. Capture channel display preferences as well as JSON config.
2. **Prepare fresh state.** With live UI access confirmed and recovery ready,
   stop watchdog/Crow and any conflicting serial reader. Quarantine active Crow
   base/override files, prior app preference state, and legacy migration inputs.
   Keep historical data recoverable without feeding it into the initial test.
3. **Install the published artifact.** Use the node's package manager and verify
   the installed version/payload. An upgrade hook must not silently restore the
   prior active configuration. Record exactly how factory state was established.
4. **First browser load.** Open `/apps/crow/index.html` through the node's HTTP
   service. Check page errors, connection state, AREDN/preset channels and `/help`.
   No radio should be required for the AREDN channel.
5. **Configure backends as a user.** Follow [USB MeshCore setup](USB_MESHCORE_SETUP.md).
   Recreate the reference transport, rather than switching to another transport
   merely to make the test pass. Configure APRS/other required connections via
   documented SSH edits. Record every command with secrets redacted.
6. **Configure channels through the UI and commands.** Use `/join` for at least
   one eligible reference channel and UI controls for another. If a temporary
   test channel is needed, remove it through the UI and prove existing channels
   and labels survived. Do not append message text to a group-creation command.
7. **Finish advanced settings.** Enter slot mappings, labels, exact group options
   and room records through supported surfaces. If a setting has no UI/command
   surface, record the gap and the explicit SSH edit used.
8. **Storage.** Use non-formatting storage commands, check state and quotas,
   and verify persistence. Restore historical content only as a separately
   recorded data-preservation action, not as a substitute for entering settings.
9. **Compare.** Compare effective base+override values and per-channel UI state
   against the private worksheet. Report differences by field, without secrets.
10. **Restart and reconnect.** Restart Crow, refresh the browser, and require the
    same channel settings, USB storage state, current backend handshakes, and
    service enablement. Report a reboot test separately if one was authorized.
11. **Close.** Check final source/version/configuration identities and service
    health; remove only task-created temporary files. Retain the recovery archives
    and note any unresolved differences or steps requiring documentation/fixes.

## Backend setup-script checks

Run `node tests/run_backend_setup_script_tests.js` on a Linux development host
with Python 3, BusyBox, and bubblewrap. The test executes unchanged scripts in
isolated namespaces, mocking package managers, devices and service actions.

It covers fresh-install/upgrade/remove ordering, upgrade configuration
preservation, apk and opkg USB storage paths, dependency failures, unsupported
filesystems, no-format assimilation, watchdog recovery decisions, bridge
re-enumeration, procd service parameters, and the runner entry point.

Also run the serial resolver, backend selector, serial/TCP protocol, and
channel/browser regressions. Keep isolated execution results separate from
live USB ownership, physical reconnect, and RF-delivery results.

## Result record template

| Step | Expected | Observed | Pass / Fail / Blocked | Evidence |
| --- | --- | --- | --- | --- |
| Backup and recovery verification | Complete private verified backup | | | |
| Fresh install and initial UI | Version correct, no old config imported | | | |
| Backend script execution | Dependencies, startup and failures handled | | | |
| USB identity and handshake | Correct sole owner, fresh self-info | | | |
| UI and command configuration | Reference settings recreated | | | |
| Post-restart parity | Settings and ready state retained | | | |
| Final preservation/cleanup | Recovery data intact, no stray test state | | | |

List documentation gaps and code defects independently. Never mark the live
test passed when browser access, fresh installation, or configuration parity
remains blocked.
