# MeshCore USB Serial Companion backend

Crow's USB Serial Companion support targets the binary MeshCore Companion
protocol used by a directly attached RAK19003 + RAK4631 radio. It is not a
line-oriented CLI and Crow must not parse text from `meshcore-cli` or shell out
to it. `meshcore-cli` is useful as a reference client for hardware validation.

Expected device paths are `/dev/ttyACM0` and `/dev/ttyUSB0`. Serial support is
experimental and opt-in; UDP remains the default and the existing TCP API
backend is unchanged.

Draft configuration:

```json
{
  "meshcore": {"backend": "serial-api"},
  "meshcore_serial_api": {
    "enabled": true,
    "device": "/dev/ttyACM0",
    "baud": 115200,
    "frame_mode": "auto",
    "app_start_profile": "meshcore_cli"
  }
}
```

Validate hardware before enabling it:

```sh
python3 tools/test_meshcore_serial_companion.py /dev/ttyACM0 --mode auto
python3 tools/test_meshcore_serial_companion.py /dev/ttyUSB0 --mode framed --profile meshcore_cli
```

The script requires `pyserial`. Serial framing and the `appStart` profile are
hardware-dependent and must be verified on the actual radio. The current Crow
ucode backend is a safe disabled skeleton where direct serial I/O is not
available on the platform. As an optional bridge, run `ser2net` or `socat` to
expose the validated framed serial stream on localhost (for example TCP port
4404), then configure the existing `meshcore_tcp_api` with host
`127.0.0.1` and port `4404`.
