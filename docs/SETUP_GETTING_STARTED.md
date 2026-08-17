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

You should see an empty chat interface and a **Channels** section.

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

Crow will discover channels automatically. You should see them in the **Channels** panel within a few seconds.

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
│   └── Auto-sync from radio
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
you want direct queue draining, channel discovery, and direct-message
verification.

For details, see [Backend Selection Guide](BACKEND_SELECTION.md).

---

## Channel Configuration

Channels in Crow mirror your radio's channels. You don't manually create channels—they're discovered from your Meshtastic or MeshCore device.

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

For details, see [Channel Management Guide](CHANNELS.md).

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
