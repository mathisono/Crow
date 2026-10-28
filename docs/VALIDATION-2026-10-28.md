# Channel join and settings validation — 2026-10-28

Base revision: `d8805f6558c3c1324b8dfc5a9f628e9b9a10997e`.

## Confirmed defects and changes

- The short `/join` handler existed but had no `case "join"` dispatch label.
  Restore dispatch; retain the existing group syntax and long-form command.
- Opening settings before the first channel list dereferenced `null`.
  Display connection status and prevent replacing unseen channel data.
- A connected empty list had no add control. Provide **Add channel** and disable
  saving until there is a valid entry.
- Invalid rows could be silently dropped while other channel state was already
  modified. Validate the complete list, clone state, and reject invalid saves.
- Preserve channel flags after a save; refresh an open editor from server data
  after reconnects or another client's channel change. Reject saves while the
  socket is closing, even before its close event arrives.
- Correct the guide: AREDN includes its default channel without a LoRa radio;
  Crow can create additional local channels.

## Checks performed

| Check | Result |
| --- | --- |
| `tests/run_all.sh` with Playwright and Chromium | All 19 Node runners exited successfully. |
| New channel-settings browser suite | 11 checks passed using the real HTML, CSS, and JavaScript with synthetic WebSocket events and network requests blocked. |
| Existing rendering browser suite | 12 checks passed. |
| Canonical join fixture on BB5, AREDN `20261024-26fe06b0` | 7 native ucode checks passed against the changed dispatcher, group code, and crypto implementation with inert service dependencies. |
| Regression negative controls against the base revision | Short-join check failed; all 11 new channel-settings checks failed, as expected. |
| AREDN APK and IPK builds | Both built successfully; packaged command, UI, and platform files match the tested source. No development test hooks shipped. |
| BB5 integrity check | Boot ID, Crow PID, override configuration, and checked installed source/UI hashes remained unchanged; temporary native fixture removed. |
| `git diff --check` | Passed. |

The development host has no ucode interpreter. Optional mirrored ucode checks
and the four standalone ucode suites were explicitly skipped there; only the
new join fixture was separately run natively on BB5. This is not a claim that
the entire suite ran under ucode.

Builds used the local test version `0.0.2-rchanneltest20261028`; no package was
installed, committed, or published. No live channels were created, messages
sent, or services restarted.

## Release and reporter status

The latest published release checked on this date is
[`v0.0.2-r21415324`](https://github.com/mathisono/Crow/releases/tag/v0.0.2-r21415324),
published 2026-09-06. A source fix does not update those downloadable artifacts.
Recent main also contains the service-watcher compatibility and command-reply
rendering fixes; old packages do not necessarily contain them.

The original reporter's installed version and exact creation steps are still
unknown. These are independently reproduced defects, not a claim that every
cause of that reporter's missing channels has been identified. Additional
reporter feedback remains useful.
