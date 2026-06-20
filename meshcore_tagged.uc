// =====================================================================
// meshcore_tagged.uc
// =====================================================================
//
// Thin wrapper around the production MeshCore UDP backend that prepends
// a gateway tag to outbound LoRa text messages:
//
//     KJ6DZB@MCGW> Hello local MeshCore
//
// This is the MeshCore counterpart to meshtastic_tagged.uc.
//
// Activation: swap router.uc's MeshCore import from
//     import * as meshcore from "meshcore";
// to:
//     import * as meshcore from "meshcore_tagged";
//
// All other backend semantics (UDP multicast, gatekeeper enforcement at
// the router level, channel/key handling) come straight from meshcore.uc.
// Only the outbound text path is wrapped.
// =====================================================================

const meshcore = require("meshcore");
const lora_text = require("lora_outbound_text");

const DEFAULT_MAX_PAYLOAD = 150;   // MeshCore MAX_TEXT_MESSAGE_LENGTH

let gatewayIndex = 0;
let maxPayload = DEFAULT_MAX_PAYLOAD;

// Snapshot of meshcore.enabled after setup(); router.uc reads it.
export let enabled = false;

function cloneForTaggedText(msg, text)
{
    const out = {};
    for (let k in msg) {
        out[k] = msg[k];
    }
    out.data = {};
    for (let k in msg.data) {
        out.data[k] = msg.data[k];
    }
    out.data.text_message = text;
    return out;
}

function maybeTag(msg)
{
    if (!msg?.data?.text_message) {
        return msg;
    }

    const text = lora_text.prepare(msg, "meshcore", gatewayIndex, maxPayload);
    if (text === null) {
        return null;
    }
    return cloneForTaggedText(msg, text);
}

export function setup(config)
{
    const cfg = config.meshcore ?? {};
    gatewayIndex = cfg.gateway_index ?? 0;
    maxPayload = cfg.gateway_tag_max_payload ?? cfg.max_text_payload ?? DEFAULT_MAX_PAYLOAD;
    meshcore.setup(config);
    enabled = meshcore.enabled;
};

export function shutdown()
{
    meshcore.shutdown();
};

export function handle()
{
    return meshcore.handle();
};

export function recv()
{
    return meshcore.recv();
};

export function send(msg)
{
    const tagged = maybeTag(msg);
    if (tagged) {
        meshcore.send(tagged);
    }
};

export function tick()
{
    meshcore.tick();
};

export function process(msg)
{
    meshcore.process(msg);
};
