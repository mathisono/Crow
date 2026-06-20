# Channel Management Guide

**Version:** 0.0.1+  
**Updated:** 2026-06-20  
**Audience:** Users working with channels in Crow

---

## What Are Channels?

**Channels** are broadcast groups on your LoRa mesh. Each channel:

- Has a **name** (e.g., "Public", "Admin", "Weather")
- May have **encryption** (PSK: Pre-Shared Key)
- Contains **members** on the mesh
- Has a **message history**

Crow **mirrors channels from your Meshtastic or MeshCore device**. You don't create channels in Crow—you manage them on the radio, and Crow discovers them.

---

## Viewing Channels

### In Crow Web UI

Open Crow: `http://10.local.mesh/app/crow`

**Channels panel** (left sidebar):

```
📋 Channels
├─ Public (5 members, 0 unread)
├─ Admin (2 members, 3 unread)
└─ Custom #1 (3 members, 0 unread)
```

Each channel shows:

- **Name**: Channel identifier
- **Members**: Approximate node count (only with TCP backend)
- **Unread**: Number of new messages since last visit

### Sorting & Filtering

*Coming soon:* Channel search and sorting.

Currently, channels appear in the order they're reported by your radio.

---

## Messaging in a Channel

### Send a Message

1. Click a **channel name** in the left panel
2. Type message in the **text box** (bottom)
3. Press **Send** or Enter
4. Message appears in chat

### Receive Messages

Messages in the current channel appear automatically. Unread messages in other channels show a count.

### Tagging & @ Mentions

*Coming soon:* Support for @mention tags and node identification.

Currently, you can manually reference callsigns or node IDs in messages (e.g., "N0ONE: check channel 1").

---

## Channel Discovery (TCP Only)

When you use **TCP Meshtastic**, Crow **automatically discovers** all channels from your device:

### How It Works

1. Crow connects to Meshtastic on port 4403 (TCP)
2. Crow sends `want_config_id` request
3. Meshtastic responds with channel list
4. Crow displays all channels automatically
5. Crow refreshes periodically (default: 10 minutes)

### In Logs

You'll see:

```
meshtastic_API: config request sent
meshtastic_API: channel discovered: Public (index 0)
meshtastic_API: channel discovered: Admin (index 1)
meshtastic_API: all channels synced (2 channels)
```

### Manual Refresh

Channel discovery happens automatically. To force refresh:

```bash
ssh root@10.local.mesh
/etc/init.d/crow restart
```

---

## Adding New Channels

Channels are managed on your **Meshtastic device**, not in Crow.

### Via Meshtastic Mobile App

1. Open **Meshtastic** app
2. Tap **Channels**
3. Tap **Add Channel**
4. Configure:
   - **Name**: e.g., "Weather"
   - **PSK**: Generate or paste a PSK
   - **Other options**: Leave defaults unless experienced
5. Save

Within 10 minutes, the channel appears in Crow.

### Via Meshtastic Web Interface

1. Open `http://192.168.4.1`
2. Go to **Channels**
3. Click **Add Channel**
4. Fill in name, PSK, etc.
5. Save

The channel syncs to Crow automatically.

### Via Meshtastic CLI (Advanced)

```bash
meshtastic --ch-add --ch-name "Weather" --ch-index 2
```

Then restart Crow to sync:

```bash
/etc/init.d/crow restart
```

---

## Channel Security & Encryption

### How Encryption Works

- **Encryption happens on the radio**, not in Crow
- Crow **never logs or displays raw PSKs** (by design, for security)
- Messages are encrypted by Meshtastic, transmitted on the mesh, decrypted by receiving nodes

### What You'll See in Crow

For each channel, you'll see:

- ✅ **Channel name**
- ✅ **Member count**
- ✅ **Recent messages** (if your device can decrypt them)
- ❌ **Raw PSK** (never logged or displayed)
- ❌ **Encryption algorithm** (handled internally by radio)

### Public vs Private Channels

| Type | PSK | Who Can Read |
|------|-----|--------------|
| **Public** | Fixed, shared | Anyone with default PSK |
| **Private** | Custom, shared | Only authorized members |
| **Personal** | Unique | Only your node (admin) |

All work the same way in Crow—messages appear if your device can decrypt them.

---

## Switching Between Channels

### Quick Switch

Click any channel name in the left panel. The chat view switches to that channel.

### Unread Indicators

Unread message count shows on the channel name:

```
Admin (3)
└─ 3 unread messages in this channel
```

Click the channel to clear unread count.

### Last Channel Memory

Crow remembers which channel you last viewed. When you reload the page, it opens that channel.

---

## Channel-Specific Settings

Currently, channel settings are minimal in Crow:

- ✅ **View members** (TCP backend only)
- ✅ **Read message history**
- ✅ **Send messages**

Coming soon:

- ⏳ **Mute channel** (no notifications)
- ⏳ **Archive/favorite** channels
- ⏳ **Channel permissions** (read/write/admin)

---

## Troubleshooting Channels

### "No channels showing"

**If using UDP:**

→ Expected. UDP doesn't discover channels. Switch to TCP API (see [Backend Selection](BACKEND_SELECTION.md)).

**If using TCP:**

→ Check logs:

```bash
logread | grep meshtastic_API | grep channel
```

If you see no channel messages:

1. Verify device has channels configured
2. Check TCP connection: `logread | grep connected`
3. Restart Crow: `/etc/init.d/crow restart`

### "Channel has no messages"

**Possible causes:**

1. Channel is new and hasn't had messages yet
2. Messages are from before Crow started
3. Your device can't decrypt messages (wrong PSK)
4. Members haven't sent messages yet

→ Send a test message to the channel

### "Can't see messages in a channel"

**If messages don't appear after sending:**

1. Check Crow logs:
   ```bash
   logread | grep crow
   ```

2. Verify radio is connected:
   ```bash
   logread | grep meshtastic | tail -5
   ```

3. Check channel encryption:
   - Verify the device is using the right PSK for this channel
   - On Meshtastic app, check channel details

4. Try sending from Meshtastic app directly:
   - If that fails, it's a radio issue, not Crow
   - If that succeeds, it's a Crow issue (contact support)

### "Unread count not clearing"

Try:

1. Refresh the page (Cmd+R or Ctrl+R)
2. Switch to another channel, then back
3. Restart Crow: `/etc/init.d/crow restart`

---

## Channel Sync & Refresh

### Automatic Refresh (TCP Only)

Crow refreshes the channel list periodically:

```json
{
  "meshtastic_api": {
    "channel_refresh_seconds": 600
  }
}
```

Default: **10 minutes** (`600` seconds)

To change (faster refresh):

```bash
ssh root@10.local.mesh
vi /etc/crow.conf
```

Adjust `channel_refresh_seconds` (e.g., `300` for 5 minutes, `1800` for 30 minutes).

Restart:

```bash
/etc/init.d/crow restart
```

### Manual Refresh

To force an immediate refresh:

```bash
/etc/init.d/crow restart
```

Or in Crow UI (coming soon):

→ Settings → **Refresh Channels** button

---

## Advanced: Channel Index Numbers

Each channel has an internal **index** (0, 1, 2, etc.) on the radio. In logs, you might see:

```
channel discovered: Public (index 0)
channel discovered: Admin (index 1)
```

The index determines the PSK order on the device. **You don't need to worry about this in normal use**—Crow handles it automatically.

### If you're using the Meshtastic CLI:

```bash
meshtastic --ch-index 2 --ch-name "Custom"
# Adds/updates channel at index 2
```

---

## FAQ

### Q: Can I rename a channel in Crow?

**A:** No, currently not. Rename on your Meshtastic device, and Crow will sync the new name.

### Q: Can I delete a channel in Crow?

**A:** No. Delete on your Meshtastic device, and Crow will remove it from the list.

### Q: Do I need to manually add channels in Crow?

**A:** No (with TCP). Crow auto-discovers all channels. With UDP, you'll need to manage them manually (not recommended).

### Q: Can I have channels with the same name?

**A:** No. Meshtastic requires unique channel names.

### Q: What's the maximum number of channels?

**A:** Meshtastic supports 8 channels. All will appear in Crow.

### Q: Can I use the same channel name as my neighbors?

**A:** Yes, but they'll have different PSKs, so you won't see each other's messages. Different channels effectively.

### Q: Are messages stored permanently?

**A:** No. Messages are stored on your device only while it's powered on. When you power cycle, message history is cleared (unless you're using a persistent backend, which is rare).

### Q: Can I export channel history?

**A:** Not yet. Planned for future versions.

---

## Next Steps

- **[Backend Selection](BACKEND_SELECTION.md)** — Understand UDP vs TCP
- **[Meshtastic TCP Migration](MESHTASTIC_TCP_MIGRATION.md)** — Enable channel discovery
- **[Configuration Reference](CONFIG_REFERENCE.md)** — All config options
- **[Troubleshooting](TROUBLESHOOTING.md)** — More detailed help
