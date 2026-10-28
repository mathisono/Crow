# Backend selection

Crow selects one transport implementation per radio family. It does not run
TCP and UDP simultaneously for automatic failover. A configured but disconnected
TCP backend does not silently become a UDP backend.

## Configuration surface

Configure connection settings over SSH using the [base/override rules](CONFIG_REFERENCE.md#configuration-files).
The chat UI's channel-settings **Backend** dropdown binds a channel to an
already-configured backend; it does not create the radio connection.

## MeshCore

`meshcore.backend` is preferred over the older `meshcore.transport` field.
An explicit mode takes priority over implicit enable flags:

| Mode | Selected transport |
| --- | --- |
| `serial`, `serial-api`, `usb`, `usb-api` | Direct USB Companion |
| `tcp`, `tcp-api`, `api`, `companion-api` | TCP Companion |
| `udp` | UDP, unless the MeshCore block is explicitly disabled |

Without an explicit mode, enabled `meshcore_tcp_api` takes precedence over
enabled `meshcore_serial_api`/`meshcore_usb_api`; otherwise an enabled MeshCore
block selects UDP. With no MeshCore configuration, the radio backend is disabled.
Do not rely on a single `enabled: false` flag to defeat an explicit TCP/USB
selector; remove/disable the selected connection consistently and verify status.

The user-facing bindings are `meshcore.tcp`, `meshcore.serial`, and
`meshcore.udp`. A USB radio behind a local `socat` bridge uses **TCP** from
Crow's perspective. See [USB setup](USB_MESHCORE_SETUP.md) for both supported
architectures, dependencies and exclusive serial ownership.

MeshCore channel/contact discovery is discarded to bound memory use. Specify
only needed channel name/key/slot mappings. A preset channel, a TCP socket, or a
configured backend is not proof of current radio readiness.

## Meshtastic

`meshtastic.backend` takes precedence over `meshtastic.transport`:

- Explicit `api`, `tcp`, `tcp-api`, or `port-api` selects the TCP Port API.
- Explicit `udp` selects UDP when the Meshtastic block is enabled.
- Otherwise `meshtastic_api.enabled` or legacy `meshtastic_API.enabled` selects TCP.
- Otherwise an enabled Meshtastic block selects UDP; an absent block is disabled.

Use the [TCP API reference](MESHTASTIC_TCP_PORT_API_BACKEND.md) for supported
settings. Meshtastic discovery behavior must not be generalized to MeshCore.

## Verify the selected backend

After editing configuration, restart Crow, refresh the chat page, and use:

```text
/backends
/cmd info
```

Require the intended transport and current backend readiness. Then inspect
channel backend bindings and repeat the check after a service restart.
Use [the fresh-install test](FRESH_INSTALL_SETUP_TEST.md) to record connection,
UI, command and persistence results separately.
