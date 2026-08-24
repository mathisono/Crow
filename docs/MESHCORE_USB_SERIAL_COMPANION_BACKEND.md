# MeshCore USB Serial Companion Backend

Crow's USB backend uses the MeshCore Companion binary protocol directly over
the attached serial device. It is not a line-oriented CLI and does not shell
out to `meshcore-cli`.

```json
{
  "meshcore": { "backend": "serial" },
  "meshcore_serial_api": {
    "enabled": true,
    "device": "/dev/ttyACM0",
    "baud": 115200,
    "app_start_profile": "crow_zeros",
    "channel_discovery": true,
    "max_pending_rx": 4
  }
}
```

`/dev/ttyUSB0` is also supported. `meshcore_usb_api` is accepted as an alias
for `meshcore_serial_api`.

The serial backend shares the TCP backend's complete Companion implementation:

- raw 8N1 serial setup and pollable USB file descriptor;
- app-start handshake (`crow_zeros` or `meshcore_cli` profile);
- bounded `0x83` message-waiting / `0x0A` queue draining;
- direct and channel receive decoding for legacy and v3 frames;
- direct TX (`0x02`) and channel TX (`0x03`) with the same payload formats;
- channel discovery, backpressure, reconnect, and status counters.

TCP remains preferred when both TCP and serial are enabled without an explicit
transport selection. Set `meshcore.backend` to `serial` to force USB.

The AREDN runtime must provide `/bin/stty`, `fs.open()`/`read()`/`write()`, and
a pollable file descriptor for the serial device. USB CDC devices may ignore
the configured baud; USB UART bridges use it.
