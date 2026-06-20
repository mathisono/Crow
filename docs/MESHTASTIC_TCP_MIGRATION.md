# Meshtastic TCP Migration Guide

**Version:** 0.0.1+  
**Updated:** 2026-06-20  
**Audience:** Users moving from UDP multicast to TCP Port-API

---

## What You'll Gain

By switching from **UDP to TCP Meshtastic**, you get:

| Feature | UDP | TCP |
|---------|-----|-----|
| **Channel list** | ❌ Manual | ✅ Auto-discovered |
| **Channel names** | ❌ Guess | ✅ Exact names |
| **Encryption status** | ❌ Unknown | ✅ Known |
| **Member count** | ❌ N/A | ✅ Approximate |
| **Future features** | ❌ Limited | ✅ Full support |
| **Setup time** | 30 seconds | 2 minutes |
| **Reliability** | ✅ Good | ✅ Better |

---

## Prerequisites

Before you start, verify you have:

- ✅ Crow installed on AREDN node (`/etc/init.d/crow status` shows it running)
- ✅ Meshtastic device on your network (powered on, connected)
- ✅ Network connectivity: AREDN node can reach Meshtastic device
- ✅ Access to Meshtastic device IP address

---

## Step 1: Locate Your Meshtastic Device

### Via Meshtastic Mobile App

1. Open **Meshtastic** app on your phone
2. Tap **Device Info** (settings gear)
3. Note the **IP Address** (e.g., `192.168.4.1`)

### Via Meshtastic Web Interface

1. Open browser: `http://192.168.4.1`
2. Go to **Device** → **Network** → look for IP address shown as `Device IP`

### Via Meshtastic CLI (If You Have It)

```bash
meshtastic --info
```

Look for line: `IP Address: 192.168.4.1`

**Write down your IP:** `__________________`

---

## Step 2: Test Network Connectivity

Before configuring Crow, verify the AREDN node can reach your Meshtastic device:

### From AREDN Node SSH:

```bash
nc -zv 192.168.4.1 4403
```

Replace `192.168.4.1` with your actual device IP.

**Expected output:**

```
Connection to 192.168.4.1 4403 port [tcp/*] succeeded!
```

**If it fails:**

```bash
# Try pinging first
ping 192.168.4.1

# If ping works but port fails, check firewall
# on AREDN node
iptables -L -n | grep 4403
```

### Troubleshoot Network Issues

| Problem | Solution |
|---------|----------|
| Ping fails | Check device is powered on, on same network |
| Port fails | Device TCP API might be disabled (enable in Meshtastic settings) |
| Firewall blocks | Check AREDN node firewall rules |

Once `nc -zv` succeeds, proceed to Step 3.

---

## Step 3: Switch to TCP in Crow Settings

### Via Web UI:

1. Open Crow: `http://10.local.mesh/app/crow`
2. Click **Settings** (gear icon, top right)
3. Scroll to **Meshtastic** section
4. Under **Backend**:
   - Select: **TCP Port-API**
   - **Host**: `192.168.4.1` (your device IP)
   - **Port**: `4403` (default, don't change)
5. Check: **Enable channel discovery**
6. Check: **Enabled** (if not already checked)
7. Optional: **Channel refresh**: `600` (10 minutes, standard)
8. Click **Save**

### Via Config File (Advanced):

If you prefer editing config directly:

```bash
ssh root@10.local.mesh
vi /etc/crow.conf
```

Add or update:

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

Save and restart:

```bash
/etc/init.d/crow restart
```

---

## Step 4: Verify Connection

Wait **5-10 seconds** for Crow to connect and discover channels.

### Check Channels Panel

In Crow web UI:

- **Channels** panel should now show a list:
  ```
  Public
  Admin
  (any custom channels on your device)
  ```
- Each shows: name, members, unread count

### Check Logs

Verify the backend was selected:

```bash
ssh root@10.local.mesh
logread | grep meshtastic_backend | tail -3
```

Expected output:

```
meshtastic_backend: selected tcp-port-api backend
meshtastic_API: connected tcp-port-api to 192.168.4.1:4403
meshtastic_API: config request sent, waiting for channels...
```

If you see:

```
meshtastic_API: unable to connect
```

→ Go to **Troubleshooting** section below.

---

## Step 5: Test Messaging

1. Click a channel name (e.g., **Public**)
2. Type a test message
3. Click **Send**

Message should appear on your LoRa mesh instantly.

✅ **Migration complete!**

---

## What Changed?

### In Your Crow Config

**Before (UDP):**
```json
{
  "meshtastic": {
    "enabled": true,
    "transport": "udp"
  }
}
```

**After (TCP):**
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

### In Crow Behavior

| Aspect | UDP | TCP |
|--------|-----|-----|
| **Channel list** | Manual or empty | Auto-discovered |
| **Logging** | Silent | Detailed backend messages |
| **Connection** | Broadcast (all hear) | Direct (targeted) |
| **Recovery** | Automatic | Auto-reconnect if lost |

---

## Optional: Keep UDP as Fallback

You can run **both UDP and TCP** for redundancy:

In `/etc/crow.conf`:

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
    "channel_discovery": true,
    "channel_sync": "read_only",
    "channel_refresh_seconds": 600
  }
}
```

**How it works:**
- Crow prioritizes TCP for channel discovery
- If TCP fails, Crow automatically falls back to UDP
- You get both reliability and channel discovery

**Restart Crow:**

```bash
/etc/init.d/crow restart
```

---

## Rolling Back (TCP → UDP)

If TCP stops working and you want to return to UDP:

### Via Web UI:

1. Settings → Meshtastic
2. Disable TCP API config
3. Enable UDP (should already be enabled)
4. Save

### Via Config:

```bash
ssh root@10.local.mesh
vi /etc/crow.conf
```

Remove or comment out the `meshtastic_api` section:

```json
{
  "meshtastic": {
    "enabled": true,
    "transport": "udp"
  }
  // "meshtastic_api": { ... }  // commented out
}
```

Restart:

```bash
/etc/init.d/crow restart
```

---

## Troubleshooting

### TCP Connection Fails

**Symptom:**
```
meshtastic_API: unable to connect to 192.168.4.1:4403
```

**Step 1: Verify device is on**

Power on your Meshtastic device. Wait 30 seconds.

**Step 2: Check IP address**

The IP address might have changed. Verify it's still correct:

```bash
# From Meshtastic app/web interface, re-check IP
# Update config if different
```

**Step 3: Test connectivity again**

```bash
nc -zv 192.168.4.1 4403
```

If it now succeeds, restart Crow:

```bash
/etc/init.d/crow restart
```

**Step 4: Check firewall**

If `nc` fails but device is on, firewall might be blocking:

```bash
# From AREDN node
iptables -L -n | grep 4403

# Try temporarily disabling firewall (advanced)
# Or add rule to allow port 4403
```

**Step 5: Fall back to UDP**

While troubleshooting, fall back to UDP so you can still message:

1. Settings → Meshtastic → Disable TCP API
2. Enable UDP
3. Save

### Channels Still Not Showing

**If using TCP and connected:**

```bash
logread | grep meshtastic_API | tail -10
```

Look for:

- `config request sent` — Crow asked for channels
- `channel discovered` — Crow received them
- `ERROR` — Something went wrong

**Common causes:**

1. **Device doesn't have channel discovery enabled**
   → Check Meshtastic device settings (usually enabled by default)

2. **Crow not staying connected**
   → Check logs for disconnect/reconnect cycles
   → Increase `channel_refresh_seconds` to `900` (15 min)

3. **Very new device**
   → Some Meshtastic firmware versions have limited TCP API support
   → Update Meshtastic firmware to latest version

### PSK / Encryption Keys Not Showing

✅ **This is correct behavior.** Crow intentionally does NOT log or display raw PSKs (Pre-Shared Keys) or encryption keys. Channel encryption is handled by the radio firmware, transparent to Crow.

### Device Disconnects Frequently

**Symptom:**

```
meshtastic_API: connected...
meshtastic_API: disconnected, will retry
meshtastic_API: connected...
```

**Solutions:**

1. **Check network stability**
   ```bash
   ping -c 20 192.168.4.1  # Check for packet loss
   ```

2. **Increase retry timeout**
   In `/etc/crow.conf`, add:
   ```json
   {
     "meshtastic_api": {
       ...
       "reconnect_timeout_ms": 5000
     }
   }
   ```

3. **Use UDP fallback** (see "Keep UDP as Fallback" section)

### "Not connecting at all"

**Step 1: Restart Crow**

```bash
/etc/init.d/crow restart
sleep 2
logread | grep meshtastic | tail -5
```

**Step 2: Restart device**

Power cycle Meshtastic device. Wait 30 seconds.

**Step 3: Factory reset (last resort)**

If still failing, backup your Meshtastic config and factory reset the device. This is rare and usually not necessary.

---

## FAQ

### Q: Will my UDP messages be lost when I switch to TCP?

**A:** No. Switch at any time—existing messages in channels are unaffected. New messages will come through TCP.

### Q: Can I switch back to UDP later?

**A:** Yes, any time. Just disable TCP API and enable UDP in settings. Restart Crow.

### Q: Do I need to update my Meshtastic firmware?

**A:** No, but recommended. Meshtastic v2.1+ has better TCP API support. Check your device.

### Q: Will other nodes see my messages?

**A:** Yes. TCP is only between Crow and your device. Messages are transmitted on the radio normally—all mesh nodes hear them.

### Q: Can I connect to multiple Meshtastic devices?

**A:** Currently, Crow connects to one Meshtastic device. Multiple device support is planned.

### Q: Is TCP or UDP faster?

**A:** About the same. TCP has slightly more overhead but is more reliable.

### Q: What if my device doesn't support TCP?

**A:** Use UDP. Most modern Meshtastic devices (esp32, nrf, etc.) support TCP. Very old devices might not.

---

## Next Steps

- **[Backend Selection Guide](BACKEND_SELECTION.md)** — Detailed comparison of UDP vs TCP
- **[Channel Management](CHANNELS.md)** — Working with discovered channels
- **[Troubleshooting](TROUBLESHOOTING.md)** — More detailed troubleshooting
- **[Configuration Reference](CONFIG_REFERENCE.md)** — All config options explained
