# Set up a USB MeshCore Companion on AREDN

Applies to Crow 0.0.3-r2, with notes for older releases. A USB **radio** and USB
**message storage** are different devices and use different setup paths.

## 1. Choose one connection method

| Method | Crow backend | Serial-port owner | Extra requirement |
| --- | --- | --- | --- |
| Direct USB | `meshcore.serial` | Crow | Compatible `crow-rawtty` helper or `stty` |
| USB-to-local-TCP bridge | `meshcore.tcp` | `socat`, supervised by `crow-serial-bridge` | `socat` and a bridge init script |

BB5's existing setup uses the second method: USB Companion → local bridge
on `127.0.0.1:4405` → Crow TCP backend. Selecting `meshcore.tcp` in that
configuration is correct even though the radio is physically connected by USB.
Do not run the bridge and direct-USB backend against the same serial port.

There is no backend-setup screen in Crow's chat UI. Configure connections over
SSH, then use the channel UI and slash commands to finish setup.

## 2. Firmware, drivers, and identity

Use firmware that exposes the **MeshCore Companion binary protocol over USB**,
not a repeater or text-console firmware. Confirm USB capability for the exact
board/build; a firmware name containing “BLE” alone does not establish whether
its USB Companion endpoint is available.

For CDC ACM radios on current AREDN:

```sh
apk update
apk add kmod-usb-acm
ls -l /dev/ttyACM* /dev/ttyUSB* 2>/dev/null
```

On older opkg firmware, use `opkg update` and `opkg install kmod-usb-acm`.
A `/dev/ttyUSB*` adapter may need its chipset-specific USB-serial driver.
Use packages from the node's matching firmware repositories.

`platforms/aredn/usb-setup.sh` installs **mass-storage** support. It is not a
MeshCore-radio installer and does not install `kmod-usb-acm` or `socat`.

To inspect a CDC ACM radio's USB vendor/product identity:

```sh
d=$(readlink -f /sys/class/tty/ttyACM0/device)
while [ -n "$d" ] && [ "$d" != / ]; do
    if [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ]; then
        cat "$d/idVendor" "$d/idProduct"
        break
    fi
    d=${d%/*}
done
```

Device numbers can change after reconnect. Do not assume that `ttyACM0` will
always be the same device when several USB serial devices are attached.

## 3A. Reproduce the USB-to-local-TCP bridge setup

Install the dependency and the init helper from the matching Crow source tag.
The package includes `/usr/local/crow/crow-serial-bridge`, but intentionally
does **not** install this node-specific init service automatically.

```sh
apk add socat
curl -fL https://raw.githubusercontent.com/mathisono/Crow/v0.0.3-r2/tools/bb5-crow-serial-bridge.init \
  -o /etc/init.d/crow-serial-bridge
chmod 755 /etc/init.d/crow-serial-bridge
```

For opkg firmware, install `socat` with opkg instead. Inspect the downloaded
init script before enabling it. Its `CROW_SERIAL_USB_ID=239a:8029` setting is
the BB5 radio's identity; change it to your radio's vendor/product pair.
For multiple identical devices, set `CROW_SERIAL_USB_SERIAL` to select one
particular device. The resolver prefers the requested identity, permits a sole
ACM-device fallback, and refuses an ambiguous selection.

Check selection without opening the radio:

```sh
CROW_SERIAL_USB_ID=239a:8029 /usr/local/crow/crow-serial-bridge --resolve
/etc/init.d/crow-serial-bridge enable
/etc/init.d/crow-serial-bridge start
/etc/init.d/crow-serial-bridge status
```

Stop any competing radio monitor or direct-serial Crow backend first.
The bridge binds to **loopback only**, port 4405. Do not expose that unauthenticated
binary radio stream on the mesh or WAN.

Using the [configuration-file rules](CONFIG_REFERENCE.md#configuration-files),
edit the existing Crow configuration to add these connection settings. Merge
these fields; do not replace unrelated settings or restore an old configuration
over the new install.

```json
{
  "meshcore": { "enabled": true, "backend": "tcp" },
  "meshcore_tcp_api": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 4405,
    "app_start_profile": "crow_zeros",
    "channel_discovery": false,
    "channel_slots": {
      "0": "MeshCore izOH6cXN6mrJ5e26oRXNcg=="
    }
  }
}
```

The wrapper rescans after the serial/TCP bridge exits, including after USB
re-enumeration. A running service or open TCP port alone is not a successful
Companion handshake; check Crow's backend status after configuration.

## 3B. Alternative: direct USB

This is a different transport, not an additional connection to the same radio.
Stop and disable an existing `crow-serial-bridge` service before selecting it.

```json
{
  "meshcore": { "backend": "serial-api" },
  "meshcore_serial_api": {
    "enabled": true,
    "device": "/dev/ttyACM0",
    "baud": 115200,
    "frame_mode": "framed",
    "channel_discovery": false,
    "channel_slots": {
      "0": "MeshCore izOH6cXN6mrJ5e26oRXNcg=="
    }
  }
}
```

The 0.0.3-r2 packages bundle a **MIPS big-endian soft-float** serial
helper. On another CPU architecture, provide a matching build or supported
`stty`; `all`/`noarch` package metadata does not make that executable universal.
See [direct-USB protocol and build details](MESHCORE_USB_SERIAL_COMPANION_BACKEND.md).

## 4. Match Crow channels to the radio's existing slots

Crow deliberately does not retain MeshCore channel/contact discovery. Adding
a channel in Crow does not automatically configure the radio's memory slots.

1. Record the exact channel name, Base64 key, and slot already on the radio.
2. Add the channel through Crow's channel settings or `/channels join NAME KEY`.
3. Select `meshcore.tcp` for the local bridge, or `meshcore.serial` for direct USB.
4. Add the exact same `NAME KEY` under the backend's `channel_slots` object,
   indexed by the radio slot (`0`–`7`). Do not put keys in shared logs/screenshots.
5. Preserve the standard public mapping and any other required slot mappings.

For example, a private slot mapping is `"1": "LocalOps <actual-base64-key>"`.
Replace the placeholder with the radio's key. A different name/key tuple is a
different Crow channel even if its displayed label looks similar.

Do not use `/cmd meshcore private ...` merely to restore a Crow-side mapping:
that command provisions radio state. Use it only when a radio-side change is
intended. A fresh Crow setup test can leave the radio's existing slots intact.

## 5. Verify, restart, and verify again

```sh
/etc/init.d/crow restart
/etc/init.d/crow status
/etc/init.d/crow-watchdog status
```

In Crow's message box, enter commands without additional message text:

```text
/backends
/help
/channels local
```

Require a **current Companion self-info handshake**, not merely a configured
backend or a connected TCP socket. Confirm the intended transport, all channel
bindings and slot mappings, then restart Crow and check they remain correct.
Capture only redacted status; channel-list replies can contain keys.

In 0.0.3-r1 and later, the channel editor accepts names up to 32 characters, matching
MeshCore's limit. Confirm the exact name/key before adding the corresponding
`channel_slots` entry. If still using 0.0.3-r0, the editor truncates typed names
at 11 characters: use `/channels join NAME BASE64KEY`, then set the backend
and preferences in the UI without retyping the name.

Room-server setup is separate from channel setup. The room-add slash command
splits on whitespace, so use a single-word alias with
`/cmd meshcore room add ALIAS PUBLICKEY PASSWORD`. If an existing room name
contains spaces, edit only that record's `name` over SSH afterward and restart
Crow. Adding a room record is not a login; do not run `room login` merely to
test configuration parity.

A controlled USB unplug/replug test must check that the bridge resolves the
radio again and Crow completes a new handshake. Handshake/queue-drain success
is not proof of RF delivery; that requires a separately authorized exchange
with an independent radio.

For the reproducible fresh-install checklist and pass/fail evidence requirements,
see [Fresh-install setup test](FRESH_INSTALL_SETUP_TEST.md).
