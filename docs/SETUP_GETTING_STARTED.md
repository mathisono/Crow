# Crow: Getting Started Guide

**Version:** 0.0.2  
**Updated:** 2026-06-20  
**Audience:** New users, Raven migration, operators new to mesh protocols

---

## What is Crow?

Crow is a **LoRa mesh messaging application** for AREDN (Amateur Radio Emergency Data Network) nodes. It lets you send and receive text messages across LoRa radios in a resilient, fault-tolerant way.

Unlike Raven (which focuses on cross-platform APRS bridging), Crow is **purpose-built for LoRa radio mesh**. It integrates with two main LoRa radio systems:

- **Meshtastic**: Popular open-source ESP32-based LoRa platform
- **MeshCore**: Professional-grade LoRa mesh platform

---

## Quick Start (2 minutes)

### 1. **Install Crow on Your AREDN Node**

Download the latest IPK from the Crow GitHub releases, or ask your mesh admin for the package:

```bash
opkg install crow_0.0.2-r*.ipk
```

Crow should start automatically. Check status:

```bash
/etc/init.d/crow status
```

### 2. **Access the Web UI**

Open your browser to:

```
http://10.local.mesh/app/crow
```

(Replace `10` with your node's IP on the mesh.)

You should see an empty chat interface and a **Channels** section. MeshCore
channels are shown only when they are explicitly configured and mapped to a
radio slot; Crow intentionally drops MeshCore contact and channel discovery
data to protect low-RAM AREDN nodes.

### 3. **Add a Meshtastic or MeshCore Device**

- If you have a **Meshtastic device** on your LAN:
  - Go to **Settings** → **Meshtastic**
  - Leave defaults (UDP multicast) or switch to TCP API (see [Backend Selection](#backend-selection) below)
  - Check **Enabled**
  - Click **Save**

- If you have a **MeshCore device**:
  - Go to **Settings** → **MeshCore**
  - Leave defaults (UDP multicast) enabled, or switch to TCP Companion API if
    you want the direct bridge path
  - Click **Save**

Crow will show the public channel and any explicitly configured channel-slot
mappings. MeshCore discovery is intentionally disabled; this prevents unused
contacts and channel records from consuming RAM.

### 4. **Send Your First Message**

1. Click a channel name
2. Type a message in the text box
3. Press **Send** or Enter

Done! Your message is now on the LoRa mesh.

---

## Coming from Raven?

Raven and Crow are **different applications** with different design goals:

| Feature | Raven | Crow |
|---------|-------|------|
| **Purpose** | APRS bridge + relay | LoRa mesh messaging |
| **Transports** | APRS, KISS, Winlink | Meshtastic, MeshCore |
| **Web UI** | Yes | Yes |
| **Config Location** | `/etc/raven.conf` | `/etc/crow.conf` |
| **Config Format** | JSON | JSON |
| **Service Name** | `raven` | `crow` |

### You Can Run Both

Raven and Crow can coexist on the same node. They're separate services:

```bash
/etc/init.d/raven status    # Check Raven
/etc/init.d/crow status     # Check Crow
```

### How to Migrate from Raven

1. **Install Crow** (as above)
2. **Copy your Raven callsign** into Crow Settings:
   - Raven config: `grep callsign /etc/raven.conf`
   - Crow settings: Settings → Node Info → Callsign
3. **Disable Raven if you only want Crow**:
   ```bash
   /etc/init.d/raven disable
   /etc/init.d/raven stop
   ```

That's it. Your channels will auto-discover via Meshtastic or MeshCore.

---

## What's Inside Crow?

```
Crow Node
├── Meshtastic Backend
│   ├── UDP (multicast, default)
│   └── TCP API (opt-in, recommended)
├── MeshCore Backend
│   ├── UDP (multicast, default)
│   └── TCP Companion API (opt-in, recommended)
├── Channel Discovery
│   └── Explicit configured mappings (MeshCore discovery is dropped)
├── Gatekeeper (ACL/anti-spam)
└── Web UI
    ├── Chat interface
    ├── Channel management
    └── Settings
```

---

## Backend Selection (UDP vs TCP)

### Default: UDP Multicast

When you enable Meshtastic or MeshCore, Crow uses **UDP multicast by default**:

- **Pros**: Simple, no configuration, works immediately
- **Cons**: No channel list discovery, no radio config access

### TCP Port-API (Recommended)

You can switch to **TCP Port-API** mode, which connects directly to your radio and allows:

- **Channel discovery**: Auto-sync channel list from radio
- **Cleaner logs**: See backend selection messages
- **Direct radio control**: Better access to radio-side config and telemetry

**To enable TCP Meshtastic:**

1. Settings → Meshtastic → Backend: Select **TCP API**
2. Host: Enter your Meshtastic device IP (e.g., `192.168.4.1`)
3. Port: `4403` (default)
4. Check **Enable channel discovery**
5. Save

Crow will connect and discover your channels within a few seconds.

For MeshCore, use the TCP Companion API path instead of the UDP default when
you want direct queue draining and direct-message verification. MeshCore
channel/contact discovery is intentionally disabled in Crow; configure only
the channels that are needed and map them to the radio's slots.

For details, see [Backend Selection Guide](BACKEND_SELECTION.md).

---

## Channel Configuration

Channels in Crow represent the radio channels that the operator has chosen to
keep. Meshtastic TCP can use its documented discovery path, but Crow's
low-RAM MeshCore path requires explicit channel name/key/slot mappings.

### Viewing Channels

In the **Channels** panel, you'll see:

```
Public      (built-in, unencrypted)
Admin       (admin use, encrypted)
Custom #1   (your channel, encrypted)
```

Each shows:
- Channel **name**
- Approximate **member count** (if available)
- **Unread message count**

### Adding a New Channel

To add a channel to your radio (and thus to Crow):

1. Use your **Meshtastic app** (mobile) or **MeshCore console** to add the channel to your radio
2. Restart Crow or wait for auto-refresh (default: 10 minutes)
3. The new channel will appear in Crow

### Channel Encryption

Crow **never logs raw PSKs or encryption keys**. Channel encryption is handled by the radio firmware, transparent to Crow.

## MeshCore channel soak benchmark

The public channel directory at
`https://bayareameshcore.com/channels/` (machine-readable source:
`channels.json`) is the real-world baseline for this test. The directory
contained **20 public channels** when the soak began on 2026-08-27. Those 20
entries are a traffic reference, not 20 radio slots: MeshCore exposes slots
0–7, and BB5/Hub5 currently use two mapped slots (public plus the private
test channel).

The passive monitor is used first for short five-minute soaks:

```bash
mkdir -p test-artifacts
export CROW_NODE_PASSWORD='(operator-provided node password)'
python3 tools/meshcore_channel_soak.py \\
  --node NODE1=10.0.0.2 \\
  --duration-hours 0.083333 \\
  --interval-seconds 30 \\
  --output test-artifacts/meshcore-channel-soak-5m-2slot.jsonl
```

It records the directory count/name digest, Crow service status, process RSS,
available RAM, restart count, and fatal/OOM/ucode error deltas. It does not
save channel secrets, inject traffic, alter radio channels, or retain message
contents. Run each soak alongside normal live MeshCore traffic. The raw
reports are ignored by Git; summarize the completed results in this section
before a release.

Acceptance criteria:

- both Crow services remain running for the full 24 hours;
- no new ucode, fatal, OOM, or kernel out-of-memory events;
- no unexplained Crow restarts;
- available RAM never reaches zero, with any sustained low-memory period
  investigated before release;
- channel handling is reported as mapped radio slots, separately from the
  public directory's channel count.

Preliminary live baseline at test start:

| Node | Crow | Available RAM | Crow RSS | Mapped MeshCore slots |
|---|---|---:|---:|---:|
| BB5 | running | ~7.0 MiB | not yet stable | 2 |
| Hub5 | running | ~21.3 MiB | not yet stable | 2 |

Completed five-minute two-slot soak, 2026-08-27 19:31–19:36 PDT, using 30
second samples (10 samples per node):

| Node | Service samples | Available RAM range | Crow RSS range | Probe failures | New errors | PID changes |
|---|---:|---:|---:|---:|---:|---:|
| BB5 | 10/10 running | 7.9–9.9 MiB | 3.9–4.1 MiB | 0 | 0 | 0 |
| Hub5 | 10/10 running | 25.5–27.4 MiB | 4.6 MiB | 0 | 0 | 0 |

The completed run is a five-minute, two-mapped-slot soak. Short soaks are
smoke tests, not the final release gate. A controlled slot-ramp test is
required to claim a maximum beyond the current two-slot live configuration;
adding directory entries alone would not create real MeshCore traffic. After
the short-soak series passes, repeat the selected maximum configuration for
24 hours before release.

For details, see [Channel Management Guide](CHANNELS.md).

## Keeping Crow running on AREDN

Crow is supervised by OpenWrt `procd` and is enabled at boot. The service now
continues retrying after crashes, while a separate `crow-watchdog` service
checks the RAM-backed `/tmp/crow-heartbeat` every 60 seconds and restarts Crow
if its process disappears or its event loop is stale for three minutes.

Check both services and recent recovery events with:

```sh
/etc/init.d/crow status
/etc/init.d/crow-watchdog status
logread | grep -E 'crow|Crow'
```

For maintenance, stop the watchdog first so it does not undo an intentional
Crow stop:

```sh
/etc/init.d/crow-watchdog stop
/etc/init.d/crow stop
```

Nodes are always supplied explicitly so development tools never silently
target a remembered live system:

```sh
python3 tools/meshcore_channel_soak.py --node NODE1=10.0.0.2 \
  --duration-hours 24 --interval-seconds 60 --output test-artifacts/soak.jsonl
```

---

## Troubleshooting

### "No channels found"

1. **Check radio connection:**
   ```bash
   nc -vz 192.168.4.1 4403  # for Meshtastic TCP
   ```
   If this fails, your radio isn't reachable. Check network + cable.

2. **Check backend selection:**
   - Settings → Meshtastic (or MeshCore)
   - Ensure **Enabled** is checked
   - Try switching between UDP and TCP to see which works

3. **Check logs:**
   ```bash
   logread | grep -i crow
   ```

### "Service won't start"

```bash
/etc/init.d/crow restart
logread | tail -20
```

If you see "Unable to resolve path for module", restart the service:

```bash
sleep 2 && /etc/init.d/crow restart
```

### "TCP connection fails"

1. Check Meshtastic device is powered on and reachable
2. Try pinging it:
   ```bash
   ping 192.168.4.1
   ```
3. Verify port 4403 is listening on the device
4. Fall back to UDP (no config needed)

---

## Next Steps

- **[Backend Selection Guide](BACKEND_SELECTION.md)** — Detailed guide on UDP vs TCP, pros/cons, switching
- **[Channel Management](CHANNELS.md)** — How channels work, discovery, configuration
- **[Meshtastic TCP Migration](MESHTASTIC_TCP_MIGRATION.md)** — Step-by-step migration from UDP to TCP API
- **[Configuration Reference](CONFIG_REFERENCE.md)** — All config options explained

---

## Getting Help

- **AREDN Mesh Admin**: Ask your local mesh admin for guidance
- **GitHub Issues**: https://github.com/mathisono/Crow/issues
- **Logs**: Always include `logread | grep crow` output when asking for help
