# Crow: getting started on AREDN

Updated 2026-10-28 for Crow 0.0.3-r1.

Crow provides AREDN mesh messaging with optional APRS, MeshCore, and Meshtastic
connections. **The default AREDN channel does not need a LoRa radio.**

## 1. Install the correct package

Download from [GitHub Releases](https://github.com/mathisono/Crow/releases/latest)
and verify the release checksum. Use the package manager present on the node:

```sh
command -v apk
command -v opkg
```

Current AREDN using APK:

```sh
apk add --allow-untrusted /tmp/crow-0.0.3-r1.apk
```

Older AREDN using opkg:

```sh
opkg install /tmp/crow_0.0.3-r1_all.ipk
```

Replace the example filename with the release you downloaded. The APK is
unsigned. Do not install both formats. Check the release notes for tested
firmware and CPU-specific USB-helper limitations.

Crow and its watchdog should start automatically:

```sh
/etc/init.d/crow status
/etc/init.d/crow-watchdog status
cat /usr/local/crow/version.uc
```

Upgrades preserve configuration; they are not fresh-install tests. For a
controlled clean setup on an existing node, follow the backup-first
[fresh-install test](FRESH_INSTALL_SETUP_TEST.md).

## 2. Open Crow

Use Crow's application link in the node UI, or open:

```text
http://NODE:8080/apps/crow/index.html
```

Replace `NODE` with the node's reachable hostname/IP and use its actual HTTP
port if it differs. The application entry is `/apps/crow/index.html`, not
`/app/crow` and not `10.local.mesh` as a substitute for an IP address.

Wait for the backend connection and channel list. AREDN should be present.
Other factory presets may also appear; a preset is not proof that a radio is
attached. An empty or connecting sidebar should be investigated before saving
channel settings.

## 3. Use channel settings and slash commands

Click the channel-settings gear to inspect/add channels. Save only after the
current channel list has loaded. The built-in AREDN channel is protected from
removal/renaming.

Useful commands, entered in the message box:

```text
/help
/backends
/channels local
/join %LocalOps
```

`/join %LocalOps` creates an AREDN-only channel. `/join #LocalOps` uses a shared
name-derived key. For an exact existing name/key, use the channel form or
`/channels join NAME BASE64KEY`. Keep private keys out of screenshots and logs;
channel-list replies can include them.

The 0.0.3-r1 editor accepts names up to 32 characters. If still using 0.0.3-r0,
use `/channels join` for names longer than 11 characters: typing them into that
older editor truncates the name. Once joined, use the UI for backend bindings
and preferences without retyping the name.

A command containing APRS group members **and trailing message text can send
that text**. For a setup-only check, do not append a message. A plain chat line
is also an actual send, not a harmless connection test.

See [Channel management](CHANNELS.md) for details.

## 4. Configure optional connections

The chat UI provides channel controls and backend bindings. It does **not**
currently provide separate Settings → MeshCore/Meshtastic/APRS pages or a
complete backend wizard. Configure host/port/device, credentials and advanced
settings over SSH, then finish channel bindings in the UI.

- **USB MeshCore:** [step-by-step USB setup](USB_MESHCORE_SETUP.md). Choose
  direct USB **or** the local-TCP bridge; never have two readers own one radio.
- **Network MeshCore:** [Companion TCP backend](MESHCORE_COMPANION_TCP_BACKEND.md).
- **Meshtastic:** [backend selection](BACKEND_SELECTION.md) and the
  [TCP API reference](MESHTASTIC_TCP_PORT_API_BACKEND.md).
- **Configuration paths:** [configuration reference](CONFIG_REFERENCE.md#configuration-files).

A fresh package is AREDN-capable without an enabled radio backend. MeshCore
channel/contact discovery is deliberately discarded; match each wanted Crow
channel to the radio's existing name/key/slot. Configuring both TCP and UDP
entries does not provide automatic failover: only the selected transport runs.

## 5. Edit configuration without losing existing settings

Crow chooses a base file and recursively merges a separate persistent override.
The override is **not** merely a temporary test file. UI changes can write it.

Stop the watchdog and Crow before SSH edits, so a later runtime save cannot
replace your edits with its older in-memory configuration:

```sh
/etc/init.d/crow-watchdog stop
/etc/init.d/crow stop
```

If no `/etc/crow.conf` exists, an operator can create one from the packaged
base before editing individual settings:

```sh
umask 077
[ -e /etc/crow.conf ] || cp -p /usr/local/crow/crow.conf /etc/crow.conf
vi /etc/crow.conf
```

Also inspect `/etc/crow.conf.override` privately: overriding fields may mask
base-file edits. Preserve unrelated keys. Do not overwrite or delete the whole
override to change a single backend. Validate each edited file as JSON:

```sh
ucode -l fs -e 'json(fs.readfile("/etc/crow.conf")); print("JSON syntax OK\n");'
```

This checks syntax, not hardware readiness or semantic correctness. Start
Crow and the watchdog after editing, wait for the UI to connect, and check
`/backends` again:

```sh
/etc/init.d/crow start
/etc/init.d/crow-watchdog start
```

## 6. Optional USB message storage

USB storage is separate from the USB radio. For an existing, backed-up data
stick, use these non-formatting commands from Crow:

```text
/storage usb scan
/storage assimilate
/storage status
```

`/storage assimilate` can install/load storage support and select an existing
drive; it does not format it. Check the drive identity before proceeding.
The standalone `usb-setup.sh format` path is destructive and is not part of
normal setup or the fresh-install test.

After enabling storage, check that the saved effective configuration contains
`storage.mode: "usb"`, the intended mountpoint/device, and the desired quotas.
A mounted drive or runtime “USB storage active” reply alone does not prove
Crow will use it after restart. If a setting is not persisted by the command,
record the gap, set that field explicitly over SSH, restart, and verify again.

This persistence gap was reproduced live on 0.0.3-r0 and remains unresolved
in 0.0.3-r1: assimilation selected USB at runtime, but a Crow restart reverted
to internal storage until the configuration was edited. The separate capacity
and free-space accounting defect is fixed in 0.0.3-r1, with native ucode
regression coverage. If still using 0.0.3-r0, verify actual capacity/free space
with `df -k /mnt/crow`; that older package overstates string-derived sizes by 10×.

## 7. Verify persistence and backend health

```sh
/etc/init.d/crow restart
/etc/init.d/crow status
/etc/init.d/crow-watchdog status
```

Refresh the browser. Check the channels, backend bindings, preferences, labels,
`/storage status`, and `/backends`. A MeshCore connection is ready only after
current Companion self-info arrives; an open TCP socket is insufficient.
RF delivery requires a separately authorized test with an independent radio.

For maintenance, stop the watchdog first so it does not restart Crow underneath
your work:

```sh
/etc/init.d/crow-watchdog stop
/etc/init.d/crow stop
```

Restart both services when maintenance is complete. No node reboot is normally
required for editing Crow configuration.

## Coming from Raven

The installer has a compatibility importer for selected legacy files when Crow
files are missing. Review the result and keep a backup. Crow/Raven config paths
are different, but that alone does not prove their ports or radio ownership
can coexist; check those before running both services.

For a fresh-install test, quarantine legacy migration inputs as well as Crow's
base/override before installing. Restoring old settings automatically would
invalidate the new-user walkthrough.

## Troubleshooting and further reading

- No AREDN channel: check Crow service/startup errors and the browser connection;
  attaching a radio is not the remedy for the missing AREDN default.
- USB radio missing: check Companion firmware, cable/power, the correct serial
  driver, and exclusive port ownership; storage setup does not install radio drivers.
- Backend configured but not ready: inspect the selected transport and current
  handshake. Do not assume an automatic UDP fallback.
- Changes disappear after restart: check base/override precedence and distinguish
  runtime state from persisted settings.
- Before sharing diagnostics, redact channel keys, passcodes, room passwords,
  private message content, and other operator data.

See [USB MeshCore setup](USB_MESHCORE_SETUP.md),
[fresh-install test](FRESH_INSTALL_SETUP_TEST.md), and
[historical channel-soak evidence](MESHCORE_CHANNEL_SOAK_HISTORY.md).
