# Meshtastic API Channel Discovery Status

Status: **implemented as an unverified runtime parser/state map; not yet hardware-validated**.

This page clarifies how far along Meshtastic TCP Port-API channel discovery is compared with the newer MeshCore TCP channel-discovery telemetry/notification work.

## Current Meshtastic API discovery state

`meshtastic_API.uc` currently has:

- corrected `FromRadio` / `ToRadio` envelope registrations;
- `FromRadio.channel` parser using tag `0x52`;
- lightweight protobuf TLV helpers;
- runtime-only `discoveredChannels` map;
- `ToRadio.want_config_id` request builder;
- connect-time config request when `channel_discovery=true`;
- periodic read-only refresh when `channel_discovery=true`;
- telemetry counters for:
  - `config_requests`
  - `config_complete`
  - `channels_discovered`
  - `pending_rx`
  - `frames_in`
  - `frames_decoded`

## Current limits

Meshtastic API discovery is **not yet equivalent** to MeshCore TCP discovery notifications.

Current missing pieces:

- no hardware validation against a Meshtastic node yet;
- no operator notification when a channel is discovered;
- no `channels_updated` counter yet;
- no UI command-reply notification like MeshCore TCP now has;
- no persistent config write, by design;
- no automatic channel routing enablement, by design;
- no radio write-back, by design.

## Comparison with MeshCore TCP discovery

MeshCore TCP discovery now has a more complete runtime notification path:

```text
CMD_GET_CHANNEL 0x1F
RESP_CHANNEL_INFO 0x12
runtime discoveredChannels map
telemetry counters
operator notification through event queue
channels refresh notification
```

Meshtastic API currently has the parser and runtime map, but still needs the same operator-notification layer.

## Required next step

Add Meshtastic API discovery notification parity with MeshCore TCP:

1. Add a `notifyOperator()` helper in `meshtastic_API.uc` using the existing event path:

   ```ucode
   global.event.queue({ cmd: "/reply", reply: lines });
   global.event.notify({ cmd: "channels" }, mergekey);
   ```

2. Add `notifyChannelDiscovered(ch, action)`.
3. Call it from `updateDiscoveredChannel()` on new or changed channels.
4. Add `channels_updated` telemetry.
5. Do not print raw PSKs.
6. Do not write `config.channels` or persistent Crow config.
7. Keep notifications clearly marked as runtime-only and unverified until hardware validation passes.

Suggested notification text:

```text
Meshtastic TCP API discovered channel
Index N: ChannelName
Runtime only; not saved to Crow config.
```

## Validation required before calling it supported

When Meshtastic TCP Port-API hardware/firmware is available:

1. Enable:

   ```json
   {
     "meshtastic": { "enabled": false },
     "meshtastic_api": {
       "enabled": true,
       "host": "<MESHTASTIC_NODE_IP>",
       "port": 4403,
       "channel_discovery": true,
       "channel_sync": "read_only",
       "channel_refresh_seconds": 600
     }
   }
   ```

2. Confirm TCP connect.
3. Confirm `ToRadio.want_config_id` is sent after connect.
4. Confirm `FromRadio.channel` frames arrive using field 10 / tag `0x52`.
5. Confirm channel name/index/PSK are parsed correctly.
6. Confirm raw PSKs are not logged or shown in UI.
7. Confirm `channels_discovered` increments.
8. Confirm operator notification appears after adding notification parity.
9. Confirm config refresh increments `config_complete`.
10. Confirm no Crow config file is modified.
11. Confirm normal inbound and outbound text still work.
12. Confirm router scope and Strict Gatekeeper still apply to Meshtastic TCP ingress.

## Recommendation

Until hardware validation passes, describe the wiki feature as:

```text
Experimental, runtime-only, unverified Meshtastic API channel discovery parser.
```

Do not describe it as full automatic channel sync or production channel discovery yet.
