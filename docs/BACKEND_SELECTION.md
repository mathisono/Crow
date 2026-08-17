# Backend Selection Guide: UDP vs TCP

**Version:** 0.0.2  
**Updated:** 2026-06-20  
**Audience:** Users wanting to understand or switch between UDP and TCP backends

---

## Overview

Crow can talk to **Meshtastic** and **MeshCore** radios in two ways:

| Aspect | UDP (Multicast) | TCP Port-API |
|--------|-----------------|--------------|
| **Setup** | Zero config, just enable | Requires radio IP + port |
| **Discovery** | ❌ No channel discovery | ✅ Auto-discovers channels |
| **Performance** | Local broadcast | Direct connection |
| **Best for** | Quick setup, simple networks | Advanced users, large networks |
| **Capability depth** | Basic bridge mode | Full bridge and radio control path |

---

## Part 1: UDP Multicast (Default)

### What is UDP?

UDP multicast broadcasts messages on your local network to **everyone listening** on a specific address and port:

- **Meshtastic UDP**: `224.0.0.69:4403`
- **MeshCore UDP**: `224.0.0.69:4402`

### Pros of UDP

- ✅ **Zero configuration**: Enable and it works
- ✅ **No IP/hostname needed**: Automatic discovery on LAN
- ✅ **Lightweight**: Low overhead
- ✅ **Compatible**: Works with any Meshtastic or MeshCore on your LAN

### Cons of UDP

- ❌ **No channel discovery**: You must manually configure channels
- ❌ **Blind operation**: Crow doesn't know which channels exist on the radio
- ❌ **Limited radio control**: Direct radio config and deeper telemetry require TCP

### UDP Configuration

In Crow Settings:

**Meshtastic:**
```json
{
  "meshtastic": {
    "enabled": true,
    "transport": "udp"
  }
}
```

**MeshCore:**
```json
{
  "meshcore": {
    "enabled": true,
    "transport": "udp"
  }
}
```

Or just enable them and accept defaults—UDP is the default.

### When to Use UDP

- You're testing Crow for the first time
- Your Meshtastic/MeshCore device is on the same LAN
- You prefer zero configuration
- Your network doesn't support TCP connections
- You're running an older device that doesn't support TCP API

---

## Part 2: TCP Port-API (Recommended)

### What is TCP Port-API?

TCP Port-API is a **direct connection** from Crow to your Meshtastic or MeshCore device:

- **Meshtastic**: Port `4403`
- **MeshCore Companion TCP**: Port `4403`

### Advantages of TCP

- ✅ **Channel discovery**: Crow automatically fetches and syncs channels
- ✅ **Channel info**: Crow knows channel names, encryption status, member count
- ✅ **Cleaner operation**: No blind broadcasting
- ✅ **Direct radio control**: Better access to radio-side config and telemetry
- ✅ **Multi-radio**: Can talk to multiple Meshtastic devices independently
- ✅ **Better logging**: Clear log messages about backend selection

### Disadvantages of TCP

- ❌ **Requires IP address**: You need to know your radio's IP
- ❌ **Needs reachability**: Network must be able to reach the radio on port 4403
- ❌ **Slightly more config**: One-time setup required

### TCP Configuration

In Crow Settings:

**Meshtastic TCP:**
```json
{
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403,
    "channel_discovery": true,
    "channel_sync": "read_only",
    "channel_refresh_seconds": 600
  }
}
```

**MeshCore TCP / Companion API:**
```json
{
  "meshcore_tcp_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403
  }
}
```

### When to Use TCP

- ✅ You want channel auto-discovery
- ✅ You're running Crow on a different machine than the radio
- ✅ Your radio has a static IP
- ✅ You care about detailed logging
- ✅ You want direct radio control and the current MeshCore TCP path

---

## Switching Between UDP and TCP

### Step-by-Step: UDP → TCP (Meshtastic)

#### 1. Find Your Meshtastic Device IP

On your Meshtastic web interface or mobile app:

```
Device Settings → Device Info → IP Address
```

Note this address (e.g., `192.168.4.1`).

#### 2. Verify Network Connectivity

From your AREDN node, test if you can reach the device:

```bash
nc -zv 192.168.4.1 4403
```

You should see:

```
Connection to 192.168.4.1 4403 port [tcp/*] succeeded!
```

If it fails:
- Check that the Meshtastic device is powered on
- Verify your AREDN node and Meshtastic device are on the same network
- Check for firewall rules blocking port 4403

#### 3. Enable TCP API in Crow

Go to **Settings** → **Meshtastic**:

1. Select **Backend**: TCP API
2. Enter **Host**: `192.168.4.1` (your device IP)
3. Enter **Port**: `4403`
4. Check **Enable channel discovery**
5. Click **Save**

#### 4. Verify It Works

Within a few seconds:

- Crow should connect to your device
- **Channels** panel will populate with channel names
- Logs will show: `meshtastic_backend: selected tcp-port-api backend`

Check logs:

```bash
logread | grep meshtastic_backend | tail -5
```

#### 5. Optional: Disable UDP

If you only want TCP, disable UDP:

1. Go to **Settings** → **Meshtastic**
2. Uncheck **Enabled** under the old UDP config (if visible)
3. Save

---

### Step-by-Step: TCP → UDP (Fallback)

If TCP stops working:

#### 1. In Crow Settings:

1. **Meshtastic** section:
   - Disable TCP API config
   - Check the UDP/Default option
   - Save

#### 2. Wait 30 seconds

Crow will fall back to UDP multicast. Channels will disappear from the panel, but messaging will still work.

#### 3. Troubleshoot TCP

Once you've switched back to UDP, debug the TCP problem:

```bash
# Check network
ping 192.168.4.1

# Check port
nc -zv 192.168.4.1 4403

# Check Crow logs
logread | grep crow | tail -20
```

---

## Hybrid Mode: UDP + TCP (Advanced)

You can run **both** simultaneously:

```json
{
  "meshtastic": {
    "enabled": true,
    "transport": "udp"
  },
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403,
    "channel_discovery": true
  }
}
```

**How it works:**

- Crow uses **TCP for channel discovery and info**
- Crow uses **UDP for messaging** (if TCP fails, falls back to UDP)
- You get best of both worlds

**When to use:**

- You want auto-discovery AND redundancy
- Your network has flaky TCP but reliable UDP
- You're testing the transition

---

## Backend Selector (How Crow Chooses)

Crow uses a **smart selector** to pick the right backend:

### For Meshtastic:

1. If `meshtastic_api.enabled == true` → **use TCP Port-API**
2. Else if `meshtastic.enabled != false` → **use UDP multicast**
3. Else → **disabled**

### For MeshCore:

1. If `meshcore_tcp_api.enabled == true` → **use TCP API** (when available)
2. Else if `meshcore.enabled != false` → **use UDP multicast**
3. Else → **disabled**

### Log Messages

Crow logs which backend it selected:

```bash
logread | grep "selected.*backend"
```

Expected output:

```
meshtastic_backend: selected udp backend
meshcore_backend: selected udp backend
```

Or:

```
meshtastic_backend: selected tcp-port-api backend
meshcore_backend: selected tcp-api backend
```

---

## Common Scenarios

### Scenario 1: New User, Single Meshtastic Device

**Recommended:** UDP (default)

No configuration needed. Just enable Meshtastic and start chatting. If you want channel discovery later, upgrade to TCP.

### Scenario 2: Experienced User, Multiple Meshtastic Devices

**Recommended:** TCP Port-API for each device

Each device gets its own config with its own IP and can be selected independently.

### Scenario 3: Meshtastic + MeshCore on Same Node

**Recommended:** UDP for both, or TCP for both

Crow can handle both simultaneously. Use whichever works best for your network.

### Scenario 4: Upgrading from Raven

**Recommended:** Start with UDP, migrate to TCP once comfortable

1. Install Crow
2. Enable Meshtastic (UDP default)
3. Test messaging
4. When ready, switch to TCP API
5. Enjoy channel discovery

---

## Troubleshooting

### "TCP connection fails"

```
meshtastic_API: unable to connect to 192.168.4.1:4403
```

**Fix:**

1. Verify device IP: `ping 192.168.4.1`
2. Check port: `nc -zv 192.168.4.1 4403`
3. Fall back to UDP: Disable TCP config, enable UDP
4. Try again after device reboot

### "Channels not showing up"

**If using UDP:**

→ Expected. UDP doesn't discover channels. Switch to TCP.

**If using TCP:**

→ Check logs:

```bash
logread | grep meshtastic_API | tail -10
```

If you see connection errors, fall back to UDP and restart Crow.

### "Which backend is actually running?"

Check logs:

```bash
logread | grep "selected.*backend" | tail -3
```

### "Should I disable UDP when using TCP?"

**No, not required.** Crow will use TCP if available, UDP as fallback. This is safer than disabling UDP entirely.

---

## Next Steps

- **[Meshtastic TCP Migration](MESHTASTIC_TCP_MIGRATION.md)** — Detailed migration walkthrough
- **[Channel Management](CHANNELS.md)** — How to work with discovered channels
- **[Configuration Reference](CONFIG_REFERENCE.md)** — All config options
- **[Troubleshooting](TROUBLESHOOTING.md)** — More detailed troubleshooting steps
