import * as meshcore_tnc from "meshcore_tnc";
import * as lora_text from "lora_outbound_text";

const DEFAULT_MAX_PAYLOAD = 150;

let gatewayIndex = 0;
let maxPayload = DEFAULT_MAX_PAYLOAD;

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
    const cfg = config.meshcore_tnc ?? config.meshcore?.tnc ?? {};
    gatewayIndex = cfg.gateway_index ?? 0;
    maxPayload = cfg.gateway_tag_max_payload ?? cfg.max_text_payload ?? DEFAULT_MAX_PAYLOAD;
    meshcore_tnc.setup(config);
};

export function shutdown()
{
    meshcore_tnc.shutdown();
};

export function handle()
{
    return meshcore_tnc.handle();
};

export function recv()
{
    return meshcore_tnc.recv();
};

export function send(msg)
{
    const tagged = maybeTag(msg);
    if (tagged) {
        meshcore_tnc.send(tagged);
    }
};

export function tick()
{
    meshcore_tnc.tick();
};

export function process(msg)
{
    meshcore_tnc.process(msg);
};
