# Crow validation: 2026-10-23

Validated the GitHub `main` baseline (`f5ee73b`) and a restored installation on
AREDN `20261023-b3502ade`, MikroTik RouterBOARD 912UAG-5HPnD. The installation
reports Crow `0.0.2-r24529585` plus the previously applied watcher compatibility
patch. Its deployed source also has the channel-export fix that was not yet on
GitHub `main`.

## Confirmed defects and corrections

- **RC startup:** the AREDN service watcher now owns a handle and exposes
  `handle()`, `changes()`, and `close()`. Preserve the legacy pipe API as well as
  the current API, distinguish a nonblocking empty read from EOF, and reconnect
  and clean up through the appropriate owner.
- **Channel command replies:** `/channels local` and `/channels world` displayed
  escaped channel markup instead of controls. Render those entries in command
  replies using rebuilt labels and explicitly parsed literal join commands.
- **Unsafe message markup:** ordinary chat could be interpreted as a channel
  list and retain arbitrary click handlers. Chat now remains escaped text;
  command controls accept only `/join` and `/channels join` literal arguments.
- **Quoted attributes:** the attribute encoder did not escape double quotes,
  corrupting inline handlers and allowing extra attributes. Encode quotes and
  use one delegated selection handler for channel/node rows.
- **Missing upstream exports:** the existing deployed export repair had not
  reached `main`. Include that repair for selected-channel text/CSV downloads,
  scoped to the requesting socket.

## Verification

| Check | Result |
| --- | --- |
| `tests/run_all.sh` with Chromium enabled | 17 runners passed |
| Focused real-DOM rendering checks (part of the above) | 12 passed; original implementation failed 9 of the initial 11 cases |
| All `tests/test_*.uc` fixtures under the target RC interpreter | 10 passed |
| Complete AREDN platform module native compilation | Passed |
| IPK and APK build with MIPS soft-float helper | Passed; test artifacts not installed |
| Crow, watchdog, serial bridge and boot enablement | Healthy |
| USB storage, live WebSocket, MeshCore TCP and APRS-IS | Healthy |
| Both application HTTP ports | HTTP 200 |
| Candidate UI with live backend | Local/world controls render, click dispatch is exact, navigation runs once, help renders, and text/CSV downloads have valid headers |

Candidate UI verification used browser request interception to serve the new
JavaScript while leaving the node's installed files untouched. Channel-button
dispatch was intercepted; no channel joins, configuration saves, test chat, or RF
test transmissions were performed. RF delivery is not covered by this review.

Image URLs initially failed workstation DNS across the SSH tunnel. Forwarding
only the same node's image aliases through that tunnel returned HTTP 200 and
left no browser resource or JavaScript errors. This was a test-route limitation,
not a demonstrated Crow image-service defect.

Node credentials, channel keys, message content, and private validation captures
are intentionally excluded from this report and the repository.
