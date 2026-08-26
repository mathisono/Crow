# MeshCore USB Serial Companion backend

Crow can talk directly to a USB-attached MeshCore Companion radio such as the
RAK3401 BLE/USB Companion build. It opens the radio's CDC serial device at
115200 baud and speaks the binary Companion protocol; it does not invoke or
parse `meshcore-cli`.

This is a real USB serial transport, not a `ser2net` or TCP bridge. It opens
single bidirectional device handle and drains the CDC port through a one-second
nonblocking timer; this avoids an AREDN `socket.poll()` hang on raw TTY handles.
After validating the device path, it configures the port with fixed command
components: `stty` when present, or Crow's bundled static `crow-rawtty` helper
on minimal AREDN images that omit `stty`. The helper uses a direct termios
`ioctl`, so its raw-mode setting persists after it exits. Only
`/dev/ttyACM<N>` and `/dev/ttyUSB<N>` paths and 115200 baud are accepted.

RAK CDC ACM boards can reset when the port is opened. Crow keeps the stream
open for a two-second startup settle period before sending `CMD_APP_START`;
sending it immediately can lose the complete self-info reply.

### AREDN package prerequisite

The AREDN package build cross-compiles `tools/crow-rawtty/main.go` as a static
helper and installs it at `/usr/local/crow/crow-rawtty`. The default target is
MIPS soft-float for ath79/BaseBox5 nodes; set `CROW_GOARCH` and the matching Go
architecture variables when building for another AREDN target. Build with Go
available in `PATH`, or set `GO_BIN` to its path:

```sh
GO_BIN=/path/to/go CROW_GOARCH=mips CROW_GOMIPS=softfloat sh platforms/aredn/build.sh
```

## Supported Companion features

- Framed serial protocol: `>` radio-to-Crow, `<` Crow-to-radio, with a
  little-endian 16-bit payload length.
- `CMD_APP_START` handshake and `RESP_SELF_INFO` recognition.
- Bounded receive parser (256-byte maximum accepted frame, fragmentation,
  resynchronisation, oversize discard, and bounded local pending queue).
- Queued-message drain: radio push `0x83` triggers `CMD_SYNC_NEXT_MESSAGE`
  (`0x0a`) and Crow applies backpressure while its local queue is full.
- Optional `CMD_GET_CHANNEL` (`0x1f`) querying for slots 0–7.
- Cleartext group text receive and send via `CMD_SEND_CHANNEL_TXT_MSG`
  (`0x03`).

Direct-message sending is intentionally not enabled yet. A direct Companion
send requires the radio's six-byte contact-key prefix and a valid
radio-owned contact/path record. Crow does not mirror those tables, and
guessing a prefix would be unsafe. Group text is the supported bidirectional
path.

## Required firmware and USB ownership

Flash the **USB Companion Radio** firmware, not the Repeater or BLE Companion
image. The serial port must be owned by Crow alone. Do not run
`meshcore-cli`, PlatformIO monitor, a terminal emulator, or a second serial
daemon against the same `/dev/ttyACM*` device while Crow is enabled.

The device uses the normal Companion framing implemented by MeshCore's
`ArduinoSerialInterface`: it is not a text console. Crow forces `framed`
operation; `raw` is rejected rather than silently emitting unusable bytes.

## Configuration

For a custom group, `channel_namekey` must be the exact group channel name and
Base64 key already configured in the radio. It must also appear in Crow's
`channels` list. If omitted, only the standard MeshCore public channel is used
as the implicit target. `tx_channel_index` is the radio memory slot for that
group (0–7).

```json
{
  "meshcore": {
    "backend": "serial-api"
  },
  "meshcore_serial_api": {
    "enabled": true,
    "device": "/dev/ttyACM0",
    "baud": 115200,
    "frame_mode": "framed",
    "app_start_profile": "meshcore_cli",
    "max_pending_rx": 4,
    "channel_discovery": true,
    "channel_refresh_seconds": 600,
    "channel_data_text_types": [],
    "direct_identity_mode": "compatibility",
    "channel_namekey": "TacNet AAECAwQFBgcICQoLDA0ODw==",
    "tx_channel_index": 0
  },
  "channels": [
    {
      "namekey": "TacNet AAECAwQFBgcICQoLDA0ODw==",
      "backend": "meshcore.serial"
    }
  ]
}
```

The example key is illustrative; replace it with the actual 16-byte Base64
key from the radio. Crow never writes discovered radio keys into its config.
When discovery sees a channel that exactly matches a configured Crow
`namekey`, it maps that radio slot for inbound group-message routing. The
configured `channel_namekey` is also mapped to `tx_channel_index` after the
normal channel setup phase.

`app_start_profile` can be `meshcore_cli` (the default) or `crow_zeros`; both
send `CMD_APP_START` followed by seven reserved bytes and `Crow`. MeshCore
firmware currently ignores the reserved bytes.

Native serial uses the same direct-identity and channel-datagram policy as the
TCP backend. Modern direct frames have no destination ID in the documented
shape, so compatibility mode accepts them as unverified queue-origin input;
`direct_identity_mode: "verified"` drops them. `0x1B` channel datagrams are
bounded and dropped unless their numeric application type is listed in
`channel_data_text_types`.

## Before enabling Crow

With Crow stopped and no other process holding the device, first confirm that
the radio is the expected one:

```sh
ls -l /dev/ttyACM* /dev/ttyUSB* 2>/dev/null
GOOS=linux GOARCH=mips GOMIPS=softfloat CGO_ENABLED=0 \
  go build -o /tmp/crow-serial-probe ./tools/crow-serial-probe
# Copy the target-architecture probe to the node, stop Crow, then run:
/tmp/crow-serial-probe --device /dev/ttyACM0 --profile zeros --seconds 5
```

The independent probe waits two seconds after opening the port, sends only the
handshake, and prints the returned Companion frames. It should show
`RESP_SELF_INFO` (`0x05`) and channel records (`0x12`). A successful probe does
not transmit a LoRa text message. Crow must be stopped while the probe owns the
device.

Then enable the configuration and restart Crow. The expected log sequence is
similar to:

```text
meshcore_backend: selected serial backend
meshcore_serial_api: opened USB Companion serial /dev/ttyACM0 at 115200; handshake in 2 seconds
meshcore_serial_api: handshake sent (CMD_APP_START); waiting for self-info/queue push
meshcore_serial_api: connected Companion device: <radio name>
```

## Verification checklist

1. Send a short message from a second MeshCore node on the configured group.
   The radio should push `0x83`, Crow should issue `0x0a`, and the message
   should enter the configured Crow channel.
2. Send a short Crow message in that same channel. Crow writes a `<` framed
   command `0x03`, containing plain-text type, the configured slot, timestamp,
   and text. The radio returns `RESP_CODE_OK` when it accepts the command;
   acceptance is not proof of remote delivery, so confirm it with a second
   receiver.
3. Check Crow's backend status/logs for `outbound_group_sent`,
   `outbound_confirmed`, `radio_errors`, `message_waiting`, and
   `sync_requests`.
4. Disconnect/reconnect USB once. Crow should report a close and reopen after
   a five-second retry interval, then send a fresh handshake.
5. If using an explicitly enabled `0x1B` text type, verify the resulting
   message still resolves through the exact discovered radio/Crow channel
   name/key/slot tuple. Unknown or binary datagrams must remain unrouted.

The final RF acceptance test is separate from this transport checklist. Use
two independent radios and exchange uniquely tagged bodies such as
`KJ6DZB@MCGW> RF-AIR-A2B-<timestamp>` and
`KN6PLV@MCGW> RF-AIR-B2A-<timestamp>`. Each token must be observed in the
other node's Crow channel, with the Companion frame and Crow counters
recorded. Handshake, channel discovery, queue drain, or a successful command
acknowledgement alone does not prove inbound RF.

## Test coverage and limits

Run the local contract checks from the repository root:

```sh
node tests/run_meshcore_serial_api_tests.js
node tests/run_meshcore_backend_selector.js
node tests/run_router_gatekeeper_matrix.js
```

The Node tests cover exact framing, outbound group packet layout,
fragmentation, resynchronisation, oversize rejection, queue-drain command
generation, source-level direct-device safety, and the `};` terminators the
AREDN ucode module parser requires for exported functions. If `ucode` is
installed, the Node runner also runs `tests/test_meshcore_serial_api.uc`
against the actual ucode module hooks. A physical RAK3401 test is still
required before deployment because USB enumeration, cable/power quality, and
radio receive semantics cannot be proven in a host-only test.
