# Troubleshooting Guide

**Version:** 0.0.2  
**Updated:** 2026-06-20  
**Audience:** Users experiencing issues with Crow

---

## Quick Fixes (Try These First)

### 1. Restart Crow

```bash
/etc/init.d/crow restart
sleep 2
/etc/init.d/crow status
```

**Fix rate:** ~30% of issues

### 2. Check Status

```bash
/etc/init.d/crow status
```

Should show:

```
running
```

If not:

```
not running
```

→ See "Service Won't Start" section below.

### 3. View Recent Logs

```bash
logread | grep crow | tail -20
```

Look for `ERROR` or `error` lines. They often explain the problem.

### 4. Power Cycle the Device

If using a Meshtastic or MeshCore device:

1. Turn off the device
2. Wait 10 seconds
3. Turn back on
4. Wait 30 seconds
5. Restart Crow: `/etc/init.d/crow restart`

**Fix rate:** ~20% of connection issues

---

## Service Won't Start

**Symptom:**

```bash
/etc/init.d/crow status
# → not running

logread | grep crow
# → Error message
```

### Step 1: Check JSON Syntax

Config file might have invalid JSON:

```bash
cat /etc/crow.conf
```

Look for:
- Missing quotes around strings
- Missing commas between fields
- Trailing commas (invalid in JSON)

**Fix:** Use an online JSON validator: https://jsonlint.com/

**Correct example:**

```json
{
  "callsign": "N0TEST",
  "meshtastic": {
    "enabled": true
  }
}
```

**Incorrect example:**

```json
{
  "callsign": "N0TEST",  // trailing comma ❌
  "meshtastic": {
    "enabled": true
  },  // trailing comma ❌
}
```

### Step 2: Check for Module Errors

If logs show "module not found" or "export" errors:

```bash
/etc/init.d/crow stop
sleep 2
/etc/init.d/crow restart
```

Wait 5 seconds, then check:

```bash
logread | grep crow | tail -5
```

If still failing, it's likely a ucode/module issue. Restart once more:

```bash
/etc/init.d/crow restart
```

**Note:** Sometimes the first start after install takes time as modules load.

### Step 3: Check Log Paths

Verify Crow data directories exist:

```bash
ls -la /usr/local/crow
ls -la /tmp/crow* 2>/dev/null || echo "no tmp files"
```

If they don't exist, reinstall:

```bash
opkg reinstall crow
/etc/init.d/crow restart
```

### Step 4: Check Network

If trying to use TCP backend, verify network:

```bash
nc -zv 192.168.4.1 4403
```

If this fails, that's your blocker. See "TCP Connection Fails" section.

---

## No Channels Showing

**Symptom:**

Crow starts, but **Channels** panel is empty.

### If Using UDP:

**Expected behavior.** UDP doesn't discover channels. 

**Fix:** Switch to TCP API:

See [Meshtastic TCP Migration Guide](MESHTASTIC_TCP_MIGRATION.md)

### If Using TCP:

Check logs:

```bash
logread | grep meshtastic_API | tail -10
```

#### Scenario 1: "unable to connect"

```
meshtastic_API: unable to connect to 192.168.4.1:4403
```

→ See "TCP Connection Fails" section below.

#### Scenario 2: "connected" but no channels

```
meshtastic_API: connected tcp-port-api to 192.168.4.1:4403
meshtastic_API: config request sent, waiting for channels...
```

Then **no discovery messages**:

**Step 1:** Verify device has channels

- Open Meshtastic app or web interface
- Check "Channels" section
- Ensure at least one channel exists

If no channels on device:

→ Add a channel in Meshtastic app, wait 30 seconds, restart Crow

**Step 2:** Check TCP API is enabled on device

- Meshtastic settings
- Look for "TCP API" or "Port API"
- Should be enabled

**Step 3:** Force refresh

```bash
/etc/init.d/crow restart
sleep 5
logread | grep channel | tail -5
```

#### Scenario 3: Only seeing partial channels

Some channels discovered, but not all:

```bash
logread | grep channel | grep discovered
```

**Possible causes:**

1. Some channels might have invalid names → Skip them
2. Discovery in progress → Wait 10-30 seconds
3. Channel sync disabled → Enable: `"channel_sync": "read_only"` in config

---

## TCP Connection Fails

**Symptom:**

```
meshtastic_API: unable to connect to 192.168.4.1:4403
meshtastic_API: retrying in 5 seconds...
```

### Step 1: Verify Device IP

Check what IP you configured:

```bash
grep "host" /etc/crow.conf
```

Verify it's still correct. If changed:

```bash
vi /etc/crow.conf
# Update host to current IP
/etc/init.d/crow restart
```

### Step 2: Check Network Connectivity

**Ping the device:**

```bash
ping -c 4 192.168.4.1
```

If **all pings fail:**

- Device is off or unreachable
- Check device is powered on
- Check both are on same network/subnet
- Check network cables

If **some pings fail (packet loss > 10%):**

- Network is unstable
- Try wired connection instead of WiFi
- Check for interference
- Restart device and AREDN node

### Step 3: Test Port Connectivity

```bash
nc -zv 192.168.4.1 4403
```

**Expected:**

```
Connection to 192.168.4.1 4403 port [tcp/*] succeeded!
```

**If it fails:**

- Device TCP API not enabled
- Device firewall blocking port 4403
- Wrong port number

**Fix:**

1. Check Meshtastic device settings for "TCP API" or "Port API"
2. Ensure it's enabled
3. Restart device
4. Try `nc` again

### Step 4: Check Firewall on AREDN Node

Your AREDN node might block outbound TCP:

```bash
iptables -L -n | grep -i output
iptables -L -n | grep 4403
```

If rules block TCP to port 4403:

- Contact your mesh admin
- Or temporarily test with UDP fallback
- (Advanced) Add rule: `iptables -A OUTPUT -d 192.168.4.1 -p tcp --dport 4403 -j ACCEPT`

### Step 5: Fall Back to UDP

While troubleshooting:

1. Settings → Meshtastic
2. Disable TCP API config
3. Enable UDP
4. Save

Crow will switch to UDP and you can still message:

```bash
/etc/init.d/crow restart
```

---

## Messages Not Appearing

**Symptom:**

Send a message, but it doesn't show up anywhere.

### Step 1: Verify Channel Selection

Ensure you selected a channel:

1. In Crow, look at **Channels** panel (left)
2. Is a channel **highlighted** (selected)?

If not:

→ Click a channel name to select it before typing

### Step 2: Check Message Text Box

Click in the message text area and type something:

```
Test message 123
```

Then click **Send** or press Enter.

**If nothing happens:**

- Try clicking **Send** button explicitly
- Try pressing Enter (not Shift+Enter)
- Refresh page (Cmd+R or Ctrl+R)

### Step 3: Check Logs for Errors

```bash
logread | grep -E "crow|meshtastic|meshcore" | tail -20
```

Look for:

- `ERROR` messages
- `unable to send` 
- `connection lost`
- `not connected`

If you see these, go to the relevant section (TCP Connection, etc.)

### Step 4: Verify Backend is Connected

Check which backend is active:

```bash
logread | grep "selected.*backend"
```

Should show:

```
meshtastic_backend: selected udp backend
```

or:

```
meshtastic_backend: selected tcp-port-api backend
```

If you see "disabled":

```
meshtastic_backend: disabled
```

→ Enable Meshtastic in Settings and restart

### Step 5: Test via Another App

Test if messaging works via Meshtastic app:

1. Open Meshtastic app on phone
2. Send a message to the same channel
3. Check if it appears in Crow

**If it appears:**

→ Crow's receive works, send might be broken (uncommon)

**If it doesn't appear:**

→ Radio/messaging broken, not Crow-specific

---

## Channels Disconnecting Frequently

**Symptom:**

```
meshtastic_API: connected tcp-port-api...
meshtastic_API: disconnected, reconnecting...
meshtastic_API: connected tcp-port-api...
```

Repeating every few seconds/minutes.

### Step 1: Check Network Stability

```bash
ping -c 30 192.168.4.1 | grep -E "loss|rtt"
```

Look at **packet loss** percentage. If > 5%:

- Network unstable
- Check WiFi signal strength
- Try wired connection
- Restart device

### Step 2: Increase Reconnect Timeout

Edit config:

```bash
vi /etc/crow.conf
```

Add:

```json
{
  "meshtastic_api": {
    "reconnect_timeout_ms": 5000
  }
}
```

(Default is usually 1000 ms. Increase to 5000.)

Save and restart:

```bash
/etc/init.d/crow restart
```

### Step 3: Check Device Logs

On Meshtastic device, check for connection errors in settings.

### Step 4: Use UDP Fallback

In the meantime, enable UDP for redundancy:

See "Keep UDP as Fallback" in [Backend Selection](BACKEND_SELECTION.md#optional-keep-udp-as-fallback)

---

## Web UI Not Loading

**Symptom:**

```
http://10.local.mesh/app/crow
```

Doesn't load or shows error.

### Step 1: Check Service Status

```bash
/etc/init.d/crow status
```

If not running:

→ See "Service Won't Start" section

### Step 2: Try Direct IP

If `.local.mesh` doesn't work, try IP directly:

```
http://10.0.0.1/app/crow  (adjust IP to your node)
```

### Step 3: Check Web Server

The web interface is served by `uhttpd` (the AREDN web server):

```bash
/etc/init.d/uhttpd status
```

If not running:

```bash
/etc/init.d/uhttpd restart
```

### Step 4: Check Browser Cache

Hard refresh the page:

- Chrome/Firefox: `Ctrl+Shift+R` (Windows) or `Cmd+Shift+R` (Mac)
- Safari: Hold Shift and click Reload

If Crow still stalls after a hard refresh, clear site data for the node as well; stale site data can break the WebSocket on older builds. If the browser console reports `Could not decode a text frame as UTF-8`, update Crow to a build that sanitizes outbound websocket payloads.

### Step 5: Check Network

Verify you can reach the AREDN node:

```bash
ping 10.0.0.1  (adjust to your node IP)
```

If ping fails:

- AREDN node offline
- Network problem
- Wrong IP

---

## Backend Selection Confusion

**Symptom:**

Not sure which backend is active, or backend keeps switching.

### Check Active Backend

```bash
logread | grep "selected.*backend" | tail -3
```

Shows exactly which backend is active.

### Understand Auto-Selection

Crow's **backend selector** chooses automatically:

**For Meshtastic:**

1. If `meshtastic_api.enabled == true` → **TCP**
2. Else if `meshtastic.enabled != false` → **UDP**
3. Else → **Disabled**

**For MeshCore:**

1. If `meshcore_tcp_api.enabled == true` → **TCP**
2. Else if `meshcore.enabled != false` → **UDP**
3. Else → **Disabled**

### Override Backend Selection

To force a specific backend, edit config:

```bash
vi /etc/crow.conf
```

**To force UDP:**

```json
{
  "meshtastic": {
    "enabled": true
  },
  "meshtastic_api": {
    "enabled": false
  }
}
```

**To force TCP:**

```json
{
  "meshtastic": {
    "enabled": false
  },
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403
  }
}
```

**To use both (TCP preferred, UDP fallback):**

```json
{
  "meshtastic": {
    "enabled": true
  },
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403
  }
}
```

Restart:

```bash
/etc/init.d/crow restart
```

---

## Unread Count Not Clearing

**Symptom:**

Channel shows "(3)" unread, but after clicking, number doesn't clear.

### Quick Fix

1. Click a different channel
2. Click back to the channel
3. Refresh page (Cmd+R or Ctrl+R)

### Nuclear Option

Restart Crow:

```bash
/etc/init.d/crow restart
```

---

## Crow Consuming Too Much CPU/Memory

**Symptom:**

AREDN node is slow or hot.

### Check Resource Usage

```bash
top
# Press Ctrl+C to exit
```

Look for `crow` or `ucode` row. If CPU% is high:

### Solutions

1. **Reduce channel refresh frequency:**

```bash
vi /etc/crow.conf
```

Change:

```json
{
  "meshtastic_api": {
    "channel_refresh_seconds": 1800  // 30 min instead of 10
  }
}
```

Restart:

```bash
/etc/init.d/crow restart
```

2. **Disable channel discovery if not needed:**

```json
{
  "meshtastic_api": {
    "channel_discovery": false
  }
}
```

3. **Use UDP instead of TCP:**

Simpler, less overhead:

```json
{
  "meshtastic": {
    "enabled": true
  },
  "meshtastic_api": {
    "enabled": false
  }
}
```

---

## Still Stuck?

### Gather Information

Before asking for help, collect:

```bash
# Service status
/etc/init.d/crow status

# Recent logs (30 lines)
logread | grep crow | tail -30

# Your config (sanitize PSKs!)
cat /etc/crow.conf

# Network test
nc -zv 192.168.4.1 4403

# Backend selection
logread | grep "selected.*backend"
```

### Where to Ask

1. **GitHub Issues:** https://github.com/mathisono/Crow/issues
   - Include: logs, config, setup description
   - Describe exactly what you tried

2. **Local Mesh Admin**
   - They may have local expertise
   - Can help with network issues

3. **AREDN Mailing List**
   - General AREDN advice

---

## Advanced Debugging

### Enable Debug Logging

```bash
vi /etc/crow.conf
```

Add:

```json
{
  "loglevel": "debug"
}
```

Restart:

```bash
/etc/init.d/crow restart
```

Now logs will be very verbose:

```bash
logread | grep crow | tail -50
```

(Much more output, helps diagnose issues)

### Test Config Without Restarting Service

```bash
cp /etc/crow.conf /etc/crow.conf.backup
cp /etc/crow.conf /etc/crow.conf.override
vi /etc/crow.conf.override
# Make test changes
/etc/init.d/crow restart
```

To roll back:

```bash
rm /etc/crow.conf.override
/etc/init.d/crow restart
```

### Manual Module Testing

For experts only:

```bash
cd /usr/local/crow
ucode -L . router.uc
```

If router loads without errors, Crow should work.

---

## Next Steps

- **[Getting Started](SETUP_GETTING_STARTED.md)** — Verify your setup
- **[Backend Selection](BACKEND_SELECTION.md)** — Choose right backend
- **[Meshtastic TCP Migration](MESHTASTIC_TCP_MIGRATION.md)** — TCP steps
- **[Config Reference](CONFIG_REFERENCE.md)** — All options

Still stuck? Open a GitHub issue: https://github.com/mathisono/Crow/issues
