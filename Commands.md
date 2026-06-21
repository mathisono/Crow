# Crow Commands

Crow exposes a set of slash commands for channel and network management. The table below lists each command, its syntax, and what it does. Use `/help` for an in‑browser reference.

| Command | Syntax | What It Does |
|---------|--------|--------------|
| **/join** | `#name …`<br>`%name …`<br>or `#name CALL1 CALL2 message …`<br>or `#name backend=NAME CALL1 message …` | Join or create a shared‑key channel (Meshtastic+MeshCore+AREDN). If the name starts with `#`, Crow hashes it to build the key. With `%` you get an AREDN‑only channel (`og==`). The longer forms let you create APRS groups, specify members and send a message. |
| **/leave** | `#name` | Leave a local channel and delete any associated APRS group. |
| **/groups** | – | List all APRS groups: name, backend (if any), member list, repeat flag. |
| **/channels world** | – | Request the list of public channels from the network bridge. If no bridge is available it falls back to local channels. |
| **/channels local** | – | Show the list of channels known locally. |
| **/channels join <name> [key]** | – | Join a channel by name (or key). If you only give the name Crow will build the key; otherwise supply the key explicitly (`<name> <key>`). |
| **/channels leave <name>** | – | Leave a local channel. |
| **/backends / backend** | – | List all configured APRS back‑ends (label + key). Requires APRS to be enabled. |
| **/storage status** | – | Show the current storage state, root and image directories. |
| **/storage usb scan** | – | Find removable USB devices that can be mounted for image storage. |
| **/storage usb enable / mount** | – | Mount a detected USB device to activate external image storage. |
| **/storage usb disable** | – | Revert to internal node storage. |
| **/storage quota images <mb>** | – | Set the per‑image quota (in megabytes). |

### Tips

* `#name` will automatically generate a 16‑byte key via SHA‑256, so you can use any readable name.
* `%name` always uses the generic AREDN key (`og==`) and is only available to AREDN nodes.
* To create an APRS group with a specific backend: `#group backend=APRS-IS-Feed CALL1 CALL2 message …`
* The `/channels world` command requires a bridge service; otherwise it falls back to the local list.

### Example Session
```
/join #PARC
Joined channel PARC

/join %test
Joined channel %test

/groups
APRS groups:  <b>MyGroup</b> [backend=APRS-IS-Feed] CALL1,CALL2

/channels world
Public channels on local network:
<div class="cj">#PARC</div>
...

/channels join #PARC
Joined channel #PARC

/channels leave #PARC
Left channel #PARC
```

> **Note:** The current `commands.uc` still supports the legacy `/join` and `/leave` syntax.  If you prefer a shorter form (e.g., `/join MC <callsign>` or `/join MT <callsign>`), those are on the roadmap in the *Channels Join/Leave Re‑work* proposal.  Once that skill is applied, replace `/join #name …` with the new short syntax.

```
