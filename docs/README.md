# Crow documentation

Start with [Getting started](SETUP_GETTING_STARTED.md). Crow supports AREDN
messaging without a LoRa radio; optional APRS, MeshCore and Meshtastic backends
add other transports.

## Operator guides

| Goal | Guide |
| --- | --- |
| Install APK/IPK and open Crow | [Getting started](SETUP_GETTING_STARTED.md) |
| Set up a USB MeshCore Companion | [USB MeshCore setup](USB_MESHCORE_SETUP.md) |
| Choose a radio transport | [Backend selection](BACKEND_SELECTION.md) |
| Add/join channels and bind a backend | [Channel management](CHANNELS.md) |
| Understand base/override configuration | [Configuration reference](CONFIG_REFERENCE.md#configuration-files) |
| Recreate a backed-up setup as a new user | [Fresh-install setup test](FRESH_INSTALL_SETUP_TEST.md) |
| Review live setup results and release workarounds | [BB5 fresh-install findings](FRESH_INSTALL_FINDINGS.md) |
| Diagnose a problem | [Troubleshooting](TROUBLESHOOTING.md) |

## Important setup facts

- Download packages from [Releases](https://github.com/mathisono/Crow/releases/latest),
  not old binary files in a source checkout. Match APK/opkg to the node and read
  the release's hardware/firmware qualification limits.
- Crow's entry page is `/apps/crow/index.html` on the node's HTTP service,
  typically `http://NODE:8080/apps/crow/index.html`.
- The chat UI has channel settings, not a general backend-configuration wizard.
  Radio connections, credentials, slot mappings and advanced fields need SSH edits.
- The factory AREDN channel needs no radio. MeshCore does not automatically
  retain/discover every radio channel; configure exact name/key/slot mappings.
- USB radio drivers, a USB-to-TCP bridge, and USB mass-storage setup are separate.
- Only the selected radio transport runs. There is no automatic TCP-to-UDP
  fallback merely because both configurations are present.
- Crow loads a base configuration and then recursively merges a persistent
  override. Do not delete the override as if it were disposable test state.
- Keys and credentials exist in configuration and may appear in channel replies.
  Keep backups private and redact diagnostics before sharing them.

## Protocol and developer references

- [Direct USB Companion backend](MESHCORE_USB_SERIAL_COMPANION_BACKEND.md)
- [TCP Companion backend](MESHCORE_COMPANION_TCP_BACKEND.md)
- [Meshtastic TCP API](MESHTASTIC_TCP_PORT_API_BACKEND.md)
- [Router/gatekeeper model](ROUTER_GATEKEEPER_MODEL.md)
- [Automated tests](../tests/README.md)
- [October 23 validation](VALIDATION-2026-10-23.md)
- [October 28 channel validation](VALIDATION-2026-10-28.md)
- [Historical MeshCore soak evidence](MESHCORE_CHANNEL_SOAK_HISTORY.md)

The fresh-install checklist distinguishes source, isolated-script, browser,
native runtime, live USB, persistence and RF results. Report the boundary of
what actually ran; a unit-test pass is not a live deployment result.
