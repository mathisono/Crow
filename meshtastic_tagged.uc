// Thin wrapper around the production Meshtastic UDP backend that prepends
// a gateway tag to outbound LoRa text messages:
//
//     KJ6DZB@MTGW> Hello Meshtastic
//
// Activation: swap router.uc's Meshtastic import from
//     import * as meshtastic from "meshtastic";
// to:
//     import * as meshtastic from "meshtastic_tagged";

const meshtastic = require("meshtastic");
const lora_text = require("lora_outbound_text");

const DEFAULT_MAX_PAYLOAD = 200;

let gatewayIndex = 0;
let maxPayload = DEFAULT_MAX_PAYLOAD;

// Snapshot of meshtastic.enabled after setup(); router.uc reads it.
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

    const text = lora_text.prepare(msg, "meshtastic", gatewayIndex, maxPayload);
    if (text === null) {
        return null;
    }
    return cloneForTaggedText(msg, text);
}

export function setup(config)
{
    const cfg = config.meshtastic ?? {};
    gatewayIndex = cfg.gateway_index ?? 0;
    maxPayload = cfg.gateway_tag_max_payload ?? cfg.max_text_payload ?? DEFAULT_MAX_PAYLOAD;
    meshtastic.setup(config);
    enabled = meshtastic.enabled;
};

export function shutdown()
{
    meshtastic.shutdown();
};

export function handle()
{
    return meshtastic.handle();
};

export function recv()
{
    return meshtastic.recv();
};

export function send(msg)
{
    const tagged = maybeTag(msg);
    if (tagged) {
        meshtastic.send(tagged);
    }
};

export function tick()
{
    meshtastic.tick();
};

export function process(msg)
{
    meshtastic.process(msg);
};
