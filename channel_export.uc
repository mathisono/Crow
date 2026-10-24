import * as nodedb from "nodedb";

function formatTime(epoch, compact)
{
    const t = localtime(epoch ?? time());
    if (compact) {
        return sprintf("%04d%02d%02d-%02d%02d%02d", t.year, t.mon, t.mday, t.hour, t.min, t.sec);
    }
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d", t.year, t.mon, t.mday, t.hour, t.min, t.sec);
}

function channelName(namekey)
{
    return split(namekey ?? "", " ")[0] ?? "channel";
}

function filenameStem(name)
{
    let stem = replace(name ?? "", /^[#%]+/, "");
    stem = replace(stem, /[^A-Za-z0-9._-]+/g, "-");
    return length(stem) > 0 ? stem : "channel";
}

function senderName(msg)
{
    if (msg.textfrom) {
        return msg.textfrom;
    }
    if (msg.from == null) {
        return "(unknown)";
    }
    const n = nodedb.getNode(msg.from, false);
    return n?.nodeinfo?.long_name ?? n?.nodeinfo?.short_name ?? `${msg.from}`;
}

function csvField(value)
{
    return `"${replace(`${value ?? ""}`, /"/g, '""')}"`;
}

export function build(namekey, messages, format, exportedAt)
{
    const name = channelName(namekey);
    const lines = [];

    if (format === "csv") {
        push(lines, "timestamp,from,message");
        for (let i = 0; i < length(messages); i++) {
            const msg = messages[i];
            const timestamp = msg.when != null ? formatTime(msg.when, false) : "";
            push(lines, `${csvField(timestamp)},${csvField(senderName(msg))},${csvField(msg.text)}`);
        }
    }
    else {
        push(lines, `Channel: ${name}`);
        push(lines, `Exported: ${formatTime(exportedAt, false)}`);
        push(lines, "");
        for (let i = 0; i < length(messages); i++) {
            const msg = messages[i];
            const timestamp = msg.when != null ? formatTime(msg.when, false) : "";
            push(lines, `[${timestamp}] ${senderName(msg)}: ${msg.text ?? ""}`);
        }
    }

    return {
        filename: `${filenameStem(name)}-${formatTime(exportedAt, true)}.${format === "csv" ? "csv" : "txt"}`,
        data: join(format === "csv" ? "\r\n" : "\n", lines)
    };
};
