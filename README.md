<img width="1332" height="387" alt="header" src="https://github.com/user-attachments/assets/b63deb00-f4d2-423f-a76e-13e053388ce4" />

# Crow Mesh Messaging Platform

Crow is the upgraded Raven!!! Crow has add fetures. Crow is a decentralized mesh messaging platform for AREDN&copy; APRS™, Meshtastic, MeshCore compatbility. Each of the backends bridge messages from other message platform to AREDN.

Send mesages, share a file, have group chats with your APRS stations. Dose your AREDN node have a USB port? Use it for file storage. 

Documentation can be found in the [Crow GitHub wiki](https://github.com/mathisono/Crow/wiki).

## Install and configure

- Download the APK (current AREDN) or IPK (older opkg firmware) from
  [GitHub Releases](https://github.com/mathisono/Crow/releases/latest).
- Start with the [Getting Started guide](docs/SETUP_GETTING_STARTED.md).
- For a USB-attached MeshCore Companion, follow
  [USB MeshCore setup](docs/USB_MESHCORE_SETUP.md), including the required
  drivers, exclusive serial-port ownership, and channel-slot mapping.
- The [fresh-install setup test](docs/FRESH_INSTALL_SETUP_TEST.md) recreates an
  operator's settings through the UI and commands without restoring a saved
  configuration over the fresh installation.
- See the [BB5 fresh-install findings](docs/FRESH_INSTALL_FINDINGS.md) for
  verified setup results and 0.0.3-r0 workarounds.

The AREDN channel does not require a LoRa radio. Channel settings are in the
chat UI; backend connections and advanced settings currently require SSH
configuration, not a separate backend-settings screen.

## Credits

Crow is derived from the
[Raven Mesh Messaging Platform](https://github.com/kn6plv/Raven), originally
developed by Tim Wilkinson with contributions preserved in this repository's
Git history. Crow was conceived, invented, and directed by Mathison and was
developed through human-directed, AI-assisted engineering using Bob/OpenAI
Codex with GPT-5.5 and GPT-5.6, Google Gemini, and Anthropic Claude 4.6.

See [CREDITS.md](CREDITS.md) for the full project provenance.

The name APRS™ (Automatic Packet Reporting System) is a registered trademark originally held by its creator, the late Bob Bruninga (WB4APR).
