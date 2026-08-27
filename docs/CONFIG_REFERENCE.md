# Configuration Reference

**Version:** 0.0.2  
**Updated:** 2026-06-20  
**Audience:** Users wanting to understand all config options

---

## Configuration Files

Crow reads configuration from (in order of priority):

1. **`/etc/crow.conf`** (main config, persistent)
2. **`/etc/crow.conf.override`** (override config, for testing)
3. **Local `./crow.conf`** (current directory, for testing)
4. **`/etc/raven.conf`** (legacy Raven config, read-only fallback)

The **first file found** wins. Typically, use `/etc/crow.conf` for production.

---

## Config Format

Crow uses **JSON format** (same as Raven):

```json
{
  "callsign": "N0ONE",
  "meshtastic": {
    "enabled": true,
    "transport": "udp"
  },
  "meshtastic_api": {
    "enabled": false
  }
}
```

**Comments are not supported** in JSON. Remove them before saving.

---

## Basic Settings

### `callsign` (string)

Your amateur radio callsign or identifier.

```json
{
  "callsign": "N0ONE"
}
```

**Defaults:** Not set

**Notes:**
- Used in message headers
- Validated for safety (alphanumeric + `-`)
- Should match your FCC license (for compliance)
- Can be updated anytime without restart

### `node_id` (number, optional)

Numeric node identifier (usually auto-assigned by radio).

```json
{
  "node_id": 12345
}
```

**Defaults:** Auto-detected from Meshtastic/MeshCore

**Notes:**
- Rarely needs manual setting
- Used internally for routing

---

## Meshtastic (UDP)

### Basic Meshtastic Configuration

```json
{
  "meshtastic": {
    "enabled": true,
    "transport": "udp"
  }
}
```

### Options

#### `enabled` (boolean)

Enable or disable Meshtastic support.

```json
{
  "meshtastic": {
    "enabled": true
  }
}
```

**Defaults:** `true`

**Behavior:**
- `true`: Crow connects to Meshtastic on startup
- `false`: Meshtastic disabled entirely

#### `transport` (string)

UDP or TCP transport (legacy, for compatibility).

```json
{
  "meshtastic": {
    "transport": "udp"
  }
}
```

**Defaults:** `"udp"`

**Valid values:**
- `"udp"` — UDP multicast (default)
- `"tcp"` — Forces TCP (use `meshtastic_api` instead)

**Notes:**
- This field is **deprecated**
- Use `meshtastic_api` config for TCP instead
- Kept for backward compatibility

---

## Meshtastic TCP API

### Basic Meshtastic TCP Configuration

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

### Options

#### `enabled` (boolean)

Enable Meshtastic TCP Port-API backend.

```json
{
  "meshtastic_api": {
    "enabled": true
  }
}
```

**Defaults:** `false`

**Behavior:**
- `true`: Crow uses TCP Port-API to Meshtastic device
- `false`: TCP API disabled, falls back to UDP

#### `host` (string)

IP address or hostname of Meshtastic device.

```json
{
  "meshtastic_api": {
    "host": "192.168.4.1"
  }
}
```

**Defaults:** Not set

**Examples:**
- `"192.168.4.1"` — IP address
- `"meshtastic.local"` — mDNS hostname
- `"10.0.0.42"` — Any reachable IP

**Notes:**
- Must be reachable from AREDN node
- Check with: `nc -zv 192.168.4.1 4403`

#### `port` (number)

TCP port on Meshtastic device.

```json
{
  "meshtastic_api": {
    "port": 4403
  }
}
```

**Defaults:** `4403`

**Valid values:** Any valid TCP port (typically 1024-65535)

**Notes:**
- Standard Meshtastic TCP API port is **4403**
- Do not change unless you've configured a custom port on the device

#### `channel_discovery` (boolean)

Enable automatic channel discovery from device.

```json
{
  "meshtastic_api": {
    "channel_discovery": true
  }
}
```

**Defaults:** `false`

**Behavior:**
- `true`: Crow fetches channel list from device on startup and periodically
- `false`: No channel discovery

**Notes:**
- Highly recommended: `true`
- Requires TCP connection to succeed

#### `channel_sync` (string)

Channel sync mode (read-only or off).

```json
{
  "meshtastic_api": {
    "channel_sync": "read_only"
  }
}
```

**Defaults:** `"off"`

**Valid values:**
- `"off"` — No channel discovery
- `"read_only"` — Read device channels, don't write
- (Future: `"read_write"` for bidirectional)

**Notes:**
- Currently only `"off"` and `"read_only"` are supported
- `"read_write"` is planned for future versions

#### `channel_refresh_seconds` (number)

How often to re-sync channel list from device.

```json
{
  "meshtastic_api": {
    "channel_refresh_seconds": 600
  }
}
```

**Defaults:** `600` (10 minutes)

**Reasonable values:**
- `300` — 5 minutes (frequent, more load on device)
- `600` — 10 minutes (balanced, recommended)
- `1800` — 30 minutes (less frequent, less load)
- `3600` — 1 hour (very infrequent)

**Notes:**
- Lower = fresher channel list, higher CPU/power
- Higher = less load, but stale channels longer
- Start with `600`, adjust to preference

---

## MeshCore (UDP)

### Basic MeshCore Configuration

```json
{
  "meshcore": {
    "enabled": true,
    "transport": "udp"
  }
}
```

### Options

#### `enabled` (boolean)

Enable or disable MeshCore support.

```json
{
  "meshcore": {
    "enabled": true
  }
}
```

**Defaults:** `false`

**Behavior:**
- `true`: Crow connects to MeshCore on startup
- `false`: MeshCore disabled entirely

#### `transport` (string)

Transport type for MeshCore.

```json
{
  "meshcore": {
    "transport": "udp"
  }
}
```

**Defaults:** `"udp"`

**Valid values:**
- `"udp"` — UDP multicast
- `"tcp"` / `"tcp-api"` / `"api"` / `"companion-api"` — MeshCore Companion TCP API
- `"serial"` / `"serial-api"` / `"usb"` / `"usb-api"` — MeshCore Companion USB serial API

**Notes:**
- UDP multicast remains the default
- TCP mode requires `meshcore_tcp_api.enabled=true` or one of the TCP/API
  transport aliases above
- USB mode uses `meshcore_serial_api` (or the `meshcore_usb_api` alias) and
  defaults to `/dev/ttyACM0` at 115200 baud

---

## MeshCore TCP API

### Configuration

```json
{
  "meshcore_tcp_api": {
    "enabled": false,
    "host": "127.0.0.1",
    "port": 4403,
    "max_pending_rx": 4,
    "channel_discovery": true,
    "channel_refresh_seconds": 600,
    "channel_data_text_types": [],
    "direct_identity_mode": "compatibility",
    "room_servers": [
      {
        "name": "N9DK Room Server",
        "public_key_b64": "<32-byte MeshCore Ed25519 public key>"
      }
    ]
  }
}
```

**Defaults:**
- `enabled`: `false`
- `host`: `"127.0.0.1"`
- `port`: `4403`
- `max_pending_rx`: `4`
- `channel_discovery`: `false`
- `channel_refresh_seconds`: `600`
- `channel_data_text_types`: `[]` (disabled by default)
- `direct_identity_mode`: `"compatibility"`
- `room_servers`: `[]`

**Notes:**
- This uses the MeshCore Companion binary API over TCP, not a line-oriented
  command/status API.
- Direct-message destinations are verified when Companion frames expose a
  destination id and self-info has provided the connected device identity.
- Modern Companion direct frames do not expose a destination id. The default
  compatibility mode accepts them as explicitly unverified queue-origin
  ingress; set `direct_identity_mode: "verified"` (or
  `strict_direct_identity: true`) to drop those frames.
- Companion channel datagrams (`0x1B`) are never treated as Crow text by
  default. Add numeric application data types such as `65535` to
  `channel_data_text_types` only when that application payload is known to be
  printable text.
- Channel discovery is read-only and runtime-only. It does not write Crow
  config or auto-map an unmatched MeshCore group slot.
- RF group receive/send is enabled per channel only after the discovered radio
  slot, channel name, and key exactly match a Crow local `channels[].namekey`.
- Keep `channel_discovery: true` when using the TCP/serial group path; a
  configured namekey without a verified radio slot remains receive/send
  disabled.
- `room_servers` is an optional list of known MeshCore room servers. Each
  entry requires a display `name` and the full 32-byte Ed25519 public key in
  base64. An omitted entry password uses MeshCore's documented default guest
  password. Crow registers the server as a Room contact, so the normal direct
  message view can be used after login.
- Private radio channels are explicit administrative operations, not inferred
  from a Crow channel name. Use `/cmd meshcore private <slot 1-7> <name>
  <16-byte-key-base64>` on each radio with the same slot, name, and key. The
  device must acknowledge `CMD_SET_CHANNEL` before Crow maps the local channel.
- Use `/cmd meshcore room login <name-or-id>` to send the room-server login
  request. A successful `0x85` login push is counted in `/backends`; regular
  direct posts then use the existing direct-message path.

## MeshCore USB Serial API

```json
{
  "meshcore_serial_api": {
    "enabled": true,
    "device": "/dev/ttyACM0",
    "baud": 115200,
    "app_start_profile": "crow_zeros",
    "max_pending_rx": 4,
    "channel_discovery": true,
    "channel_data_text_types": [],
    "direct_identity_mode": "compatibility"
  }
}
```

This is the same framed Companion protocol used by the TCP API, carried over
the local USB serial device. It includes both receive queue draining and
direct/channel transmit. Use `meshcore.backend: "serial"` to force it when
TCP is also configured.

The serial backend uses the same safety defaults as TCP: exact discovered
channel tuple proof, opt-in `0x1B` text routing, and compatibility-mode
handling for modern direct frames whose destination is not present on the
wire. Native USB handshake readiness is exposed in backend status; it is not
RF receive proof.

---

## Advanced Settings

### `loglevel` (string, optional)

Control verbosity of Crow logging.

```json
{
  "loglevel": "info"
}
```

**Defaults:** `"info"`

**Valid values:**
- `"debug"` — Very verbose (development)
- `"info"` — Normal (recommended)
- `"warn"` — Warnings and errors only
- `"error"` — Errors only

**Notes:**
- Affects system logs: `logread | grep crow`
- Change requires restart: `/etc/init.d/crow restart`

### `websocket_port` (number, optional)

Port for Crow web UI WebSocket connection.

```json
{
  "websocket_port": 4404
}
```

**Defaults:** `4404`

**Notes:**
- Usually doesn't need changing
- Must be different from other services

---

## Example Configurations

### Example 1: New User (UDP Only)

```json
{
  "callsign": "N0TEST",
  "meshtastic": {
    "enabled": true
  }
}
```

**Result:** Simple setup, UDP only, no config needed.

### Example 2: TCP Meshtastic (Recommended)

```json
{
  "callsign": "N0TEST",
  "meshtastic": {
    "enabled": true
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

**Result:** TCP with channel discovery, UDP fallback.

### Example 3: Dual Backends (Meshtastic + MeshCore)

```json
{
  "callsign": "N0TEST",
  "meshtastic": {
    "enabled": true
  },
  "meshtastic_api": {
    "enabled": true,
    "host": "192.168.4.1",
    "port": 4403,
    "channel_discovery": true,
    "channel_sync": "read_only"
  },
  "meshcore": {
    "enabled": true
  }
}
```

**Result:** Crow supports both Meshtastic and MeshCore simultaneously.

### Example 4: Minimal (Just Callsign)

```json
{
  "callsign": "N0TEST"
}
```

**Result:** Uses all defaults. UDP multicast only.

---

## Editing Configuration

### Via Web UI (Recommended)

1. Open Crow: `http://10.local.mesh/app/crow`
2. Click **Settings** (gear icon)
3. Modify values
4. Click **Save**

Crow restarts automatically with new config.

### Via SSH (Advanced)

```bash
ssh root@10.local.mesh
vi /etc/crow.conf
```

Edit the JSON, save, then restart:

```bash
/etc/init.d/crow restart
```

### Verify Config

After changing config, check logs:

```bash
logread | grep crow | tail -20
```

Look for errors or confirmation messages.

---

## Validation & Errors

### JSON Syntax Error

**Error:**
```
Error: Invalid JSON in /etc/crow.conf
```

**Fix:** Ensure all JSON is valid:
- All strings in double quotes
- Proper commas between fields
- No trailing commas
- Use online JSON validator: `https://jsonlint.com/`

### Missing Required Fields

Crow handles missing fields gracefully:

```json
{
  "callsign": "N0TEST"
}
```

✅ Valid. All other fields use defaults.

### Invalid Values

**Error:**
```
Invalid value for channel_refresh_seconds: must be number
```

**Fix:** Ensure type matches:

```json
{
  "channel_refresh_seconds": 600  // number, not "600" (string)
}
```

---

## Config Defaults (Summary)

| Option | Default | Type |
|--------|---------|------|
| `callsign` | Not set | string |
| `node_id` | Auto-detected | number |
| `meshtastic.enabled` | `true` | boolean |
| `meshtastic.transport` | `"udp"` | string |
| `meshtastic_api.enabled` | `false` | boolean |
| `meshtastic_api.host` | Not set | string |
| `meshtastic_api.port` | `4403` | number |
| `meshtastic_api.channel_discovery` | `false` | boolean |
| `meshtastic_api.channel_sync` | `"off"` | string |
| `meshtastic_api.channel_refresh_seconds` | `600` | number |
| `meshcore.enabled` | `false` | boolean |
| `meshcore.transport` | `"udp"` | string |
| `loglevel` | `"info"` | string |
| `websocket_port` | `4404` | number |

---

## Next Steps

- **[Getting Started](SETUP_GETTING_STARTED.md)** — Quick start guide
- **[Backend Selection](BACKEND_SELECTION.md)** — UDP vs TCP explained
- **[Meshtastic TCP Migration](MESHTASTIC_TCP_MIGRATION.md)** — Step-by-step migration
- **[Troubleshooting](TROUBLESHOOTING.md)** — Debug config issues
