# Crow Documentation

Welcome to **Crow**, the LoRa mesh messaging application for AREDN.

---

## I'm New. Where Do I Start?

Start here: **[Getting Started Guide](SETUP_GETTING_STARTED.md)**

It covers:
- What Crow is
- Quick 2-minute setup
- If you're coming from Raven
- Basic troubleshooting

---

## I Want to Use TCP Meshtastic (Recommended)

Follow: **[Meshtastic TCP Migration Guide](MESHTASTIC_TCP_MIGRATION.md)**

This guide walks you through:
- Finding your Meshtastic device IP
- Testing network connectivity
- Switching from UDP to TCP
- Verifying it works

---

## I Want to Understand UDP vs TCP

Read: **[Backend Selection Guide](BACKEND_SELECTION.md)**

Explains:
- How UDP multicast works
- How TCP Port-API works
- Pros and cons of each
- How to switch between them
- Hybrid mode (UDP + TCP)

---

## I Have Questions About Channels

Refer to: **[Channel Management Guide](CHANNELS.md)**

Covers:
- What channels are
- How to view and switch channels
- Adding new channels (on your radio)
- Channel discovery
- Channel encryption
- Troubleshooting channel issues

---

## I Need to Configure Everything

See: **[Configuration Reference](CONFIG_REFERENCE.md)**

Documents:
- All config file options
- Where config files live
- How to edit config
- Defaults for every setting
- Example configurations

---

## Something's Broken

Jump to: **[Troubleshooting Guide](TROUBLESHOOTING.md)**

Covers common issues:
- Service won't start
- No channels showing
- TCP connection fails
- Messages not appearing
- Step-by-step debugging

---

## Coming from Raven?

**[Getting Started](SETUP_GETTING_STARTED.md)** has a section on Raven migration. Key points:

- Raven and Crow are different applications
- Both can run simultaneously
- Crow uses `/etc/crow.conf`, Raven uses `/etc/raven.conf`
- Channel discovery is automatic with TCP (different from Raven)
- You can disable Raven if you only want Crow

---

## Doc Map

```
📚 Documentation
├─ README.md (you are here)
├─ SETUP_GETTING_STARTED.md ⭐ START HERE
│  └─ What is Crow
│  └─ 2-minute quick start
│  └─ Raven migration notes
│  └─ Basic troubleshooting
│
├─ BACKEND_SELECTION.md
│  └─ UDP explained
│  └─ TCP explained
│  └─ How to switch
│  └─ Hybrid mode
│
├─ MESHTASTIC_TCP_MIGRATION.md ⭐ FOR TCP USERS
│  └─ Step-by-step guide
│  └─ Network verification
│  └─ Testing & verification
│  └─ Detailed troubleshooting
│
├─ CHANNELS.md
│  └─ What are channels
│  └─ How to use channels
│  └─ Adding new channels
│  └─ Encryption & security
│  └─ Channel discovery
│
├─ CONFIG_REFERENCE.md
│  └─ All config options
│  └─ Where config files live
│  └─ Example configs
│  └─ How to edit config
│
├─ TROUBLESHOOTING.md
│  └─ Common issues
│  └─ Step-by-step debugging
│  └─ Where to find logs
│
├─ BACKEND_COMPLIANCE_PLAN.md (developer)
├─ MESHTASTIC_TCP_PORT_API_BACKEND.md (developer)
└─ MESHCORE_TCP_API_BACKEND.md (developer)
```

---

## Quick Reference

### Installation

```bash
opkg install crow_0.0.2-r*.ipk
/etc/init.d/crow status
```

### Access Web UI

```
http://10.local.mesh/app/crow
```

Replace `10` with your AREDN node IP.

### Check Status

```bash
/etc/init.d/crow status
```

### View Logs

```bash
logread | grep crow
```

### Restart Service

```bash
/etc/init.d/crow restart
```

### Edit Config

```bash
vi /etc/crow.conf
/etc/init.d/crow restart
```

---

## For Different Users

### 👤 Casual User (Just Want to Chat)

1. [Getting Started](SETUP_GETTING_STARTED.md) — 5 min
2. Install Crow, enable Meshtastic
3. Start chatting

### 🔧 Tech-Savvy User (Want Full Control)

1. [Backend Selection](BACKEND_SELECTION.md) — Understand options
2. [Meshtastic TCP Migration](MESHTASTIC_TCP_MIGRATION.md) — Enable TCP
3. [Config Reference](CONFIG_REFERENCE.md) — Tweak settings

### 🚀 Raven User (Migrating)

1. [Getting Started - Raven Section](SETUP_GETTING_STARTED.md#coming-from-raven)
2. Install Crow alongside Raven
3. [Meshtastic TCP Migration](MESHTASTIC_TCP_MIGRATION.md) — Better than Raven's UDP
4. Optionally disable Raven

### 🐛 Troubleshooting

1. [Troubleshooting Guide](TROUBLESHOOTING.md)
2. Gather logs: `logread | grep crow`
3. Follow step-by-step debugging
4. If stuck, open GitHub issue with logs

---

## Key Concepts

### Backend Selector

Crow uses a **smart backend selector** to choose between UDP and TCP:

- **UDP**: Default, zero config, no discovery
- **TCP**: Opt-in, channel discovery, recommended
- **Hybrid**: Both enabled, TCP prioritized, UDP fallback

See: [Backend Selection Guide](BACKEND_SELECTION.md)

### Channel Discovery

When using **TCP**, Crow automatically discovers all channels from your radio:

- ✅ Auto-sync channel list
- ✅ Know channel names & members
- ✅ No manual configuration

See: [Channels Guide](CHANNELS.md)

### Encryption

Crow **never logs raw PSKs** or encryption keys (by design):

- Encryption handled by radio firmware
- Transparent to Crow
- You can't see PSKs in Crow (intentional security feature)

See: [Channels - Security](CHANNELS.md#channel-security--encryption)

---

## Configuration Path Priority

Crow reads config from (in order):

1. `/etc/crow.conf.override` (temporary overrides)
2. `/etc/crow.conf` (main, recommended)
3. `./crow.conf` (current directory, for testing)
4. `/etc/raven.conf` (legacy Raven, read-only fallback)

The **first file found** wins. Typically use `/etc/crow.conf` for production.

See: [Config Reference](CONFIG_REFERENCE.md#configuration-files)

---

## Support

### Getting Help

1. **Check [Troubleshooting](TROUBLESHOOTING.md)** — Most issues are documented
2. **Review logs**: `logread | grep crow` — Often reveals the problem
3. **Open a GitHub issue**: https://github.com/mathisono/Crow/issues
   - Include: Your setup, log output, what you tried
4. **Ask your mesh admin** — They may have local expertise

### Reporting Issues

When filing a bug report, include:

```bash
# Your setup
logread | grep crow | tail -30

# Crow status
/etc/init.d/crow status

# Your config (sanitize PSKs)
cat /etc/crow.conf

# Backend selection logs
logread | grep backend | tail -5
```

---

## Tips & Tricks

### Faster Channel Refresh

If channels update slowly:

```json
{
  "meshtastic_api": {
    "channel_refresh_seconds": 300
  }
}
```

Change `600` (10 min) to `300` (5 min). Restart:

```bash
/etc/init.d/crow restart
```

### Run Both Raven and Crow

They can coexist:

```bash
/etc/init.d/raven status    # Check Raven
/etc/init.d/crow status     # Check Crow
```

Both will use different config files and ports.

### Test Config Before Applying

Edit a test file, then restart with it:

```bash
cp /etc/crow.conf /tmp/crow.conf.test
vi /tmp/crow.conf.test
cp /tmp/crow.conf.test /etc/crow.conf.override
/etc/init.d/crow restart
```

After testing, remove the override:

```bash
rm /etc/crow.conf.override
/etc/init.d/crow restart
```

### Debug Backend Selection

To see exactly which backend Crow chose:

```bash
logread | grep "selected.*backend" | tail -3
```

Expected:

```
meshtastic_backend: selected udp backend
meshtastic_backend: selected tcp-port-api backend
```

---

## Version Information

**Crow Version:** 0.0.2  
**Last Updated:** 2026-06-20  
**Documentation:** 100% coverage of 0.0.2 features

Planned for future versions:
- ⏳ Mute channels
- ⏳ Persistent message archive
- ⏳ MeshCore TCP API
- ⏳ Radio config write (Meshtastic)
- ⏳ @ mentions

---

## License

Crow is **open source** under the MIT license.

**Repository:** https://github.com/mathisono/Crow

---

## Feedback

Found an error in the docs? Ideas for improvement?

- **GitHub Issues**: https://github.com/mathisono/Crow/issues
- **Doc improvements**: Pull requests welcome

---

## Next Step

👉 **[Start with Getting Started Guide](SETUP_GETTING_STARTED.md)**
