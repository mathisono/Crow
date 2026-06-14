const DEFAULT_LORA_MAX_PAYLOAD = 255;
const ELLIPSIS = "...";

function normTransport(target_transport)
{
    switch (target_transport) {
        case "meshcore":
        case "meshcore_tnc":
            return "meshcore";
        case "meshtastic":
            return "meshtastic";
        default:
            return target_transport;
    }
}

export function gatewayTag(target_transport, gateway_index)
{
    const t = normTransport(target_transport);
    const idx = gateway_index ?? 0;

    switch (t) {
        case "meshcore":
            if (idx <= 0) {
                return "MCGW";
            }
            return `MCG${idx + 1}`;

        case "meshtastic":
            if (idx <= 0) {
                return "MTGW";
            }
            return `MTG${idx}`;

        default:
            DEBUG1("lora_outbound_text: unknown target transport '%s', defaulting tag to MCGW\n", target_transport);
            return "MCGW";
    }
};

function sourceCallsign(msg)
{
    return msg.originating_callsign
        ?? msg.callsign
        ?? msg.from_callsign
        ?? msg.data?.callsign
        ?? "UNKNOWN";
}

export function prepare(msg, target_transport, gateway_index, max_payload)
{
    if (!msg) {
        DEBUG1("lora_outbound_text: no message object supplied\n");
        return null;
    }

    max_payload = max_payload ?? DEFAULT_LORA_MAX_PAYLOAD;

    const cleartext = msg.data?.text_message ?? "";
    const callsign = sourceCallsign(msg);
    const tag = gatewayTag(target_transport, gateway_index);
    const header = `${callsign}@${tag}> `;
    const room = max_payload - length(header);

    if (room <= 0) {
        DEBUG1(
            "lora_outbound_text: header exceeds payload budget callsign=%s tag=%s header_len=%d max=%d\n",
            callsign,
            tag,
            length(header),
            max_payload
        );
        return substr(header, 0, max_payload);
    }

    if (length(cleartext) > room) {
        let body;
        if (room > length(ELLIPSIS)) {
            body = substr(cleartext, 0, room - length(ELLIPSIS)) + ELLIPSIS;
        }
        else {
            body = substr(cleartext, 0, room);
        }

        DEBUG1(
            "lora_outbound_text: truncated outbound target=%s tag=%s callsign=%s original=%d final=%d max=%d\n",
            target_transport,
            tag,
            callsign,
            length(cleartext),
            length(header) + length(body),
            max_payload
        );
        return header + body;
    }

    DEBUG1(
        "lora_outbound_text: formatted outbound target=%s tag=%s callsign=%s total=%d max=%d\n",
        target_transport,
        tag,
        callsign,
        length(header) + length(cleartext),
        max_payload
    );

    return header + cleartext;
};
