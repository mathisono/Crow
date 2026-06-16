import * as struct from "struct";
import * as channel from "channel";
import * as router from "router";
import * as message from "message";
import * as textmessage from "textmessage";
import * as node from "node";
import * as crypto from "crypto.crypto";
import * as groups from "groups";
import * as aprs from "aprs";

function fmtBytes(n)
{
    if (n == null) {
        return "unknown";
    }
    if (n > 1024 * 1024 * 1024) {
        return sprintf("%.1f GB", n / (1024 * 1024 * 1024));
    }
    if (n > 1024 * 1024) {
        return sprintf("%.1f MB", n / (1024 * 1024));
    }
    if (n > 1024) {
        return sprintf("%.1f KB", n / 1024);
    }
    return `${n} B`;
}

function getPublicChannels()
{
    const channels = [];
    const all = channel.getAllChannelNamekeys();
    for (let i = 0; i < length(all); i++) {
        const namekey = all[i];
        if (channel.isMeshtasticPreset(namekey) || channel.isMeshcorePreset(namekey) || channel.isAREDNPreset(namekey)) {
            push(channels, `<div class="cj">${split(namekey, " ")[0]}</div>`);
        }
        else if (ord(namekey) === 35 /* # */ || ord(namekey) === 37 /* % */ || channel.isAREDNOnly(namekey)) {
            push(channels, `<div class="cj" onclick='cmd("/channels join ${namekey}")'>${split(namekey, " ")[0]}</div>`);
        }
    }
    return sort(channels);
}

function getBridge()
{
    const services = platform.getTargetsByIdAndNamekey(null, null, true);
    for (let i = 0; i < length(services); i++) {
        const bridges = services[i].bridge;
        for (let j = 0; j < length(bridges); j++) {
            if (bridges[j].meship) {
                return services[i].id;
            }
        }
    }
    return null;
}


function currentChannelsAsSettings()
{
    return map(channel.getAllLocalChannels(), c => {
        const s = textmessage.state(c.namekey);
        return { namekey: c.namekey, max: s.max, badge: s.badge, images: s.images, telemetry: c.telemetry, winlink: s.winlink, backend: c.backend ?? "" };
    });
}

function storageSupported(id, fn)
{
    if (!platform || !platform[fn]) {
        event.queue({ cmd: "/reply", reply: [ "Storage management is not supported on this platform." ], socket: id });
        return false;
    }
    return true;
}

function csvEscape(v)
{
    v = `${v ?? ""}`;
    return `"${replace(v, '"', '""')}"`;
}

function exportMessages(id, namekey, fmt)
{
    if (!namekey) {
        event.queue({ cmd: "/reply", reply: [ "No selected channel to export." ], socket: id });
        return;
    }
    const msgs = textmessage.getMessages(namekey) ?? [];
    if (length(msgs) === 0) {
        event.queue({ cmd: "/reply", reply: [ "Selected channel has no messages to export." ], socket: id });
        return;
    }
    const reply = [ `<b>Export ${namekey}</b>`, "&nbsp;" ];
    if (fmt === "csv") {
        push(reply, "timestamp,from,message");
        for (let i = 0; i < length(msgs); i++) {
            const m = msgs[i];
            push(reply, `${csvEscape(m.time ?? m.rx_time ?? m.id)},${csvEscape(m.textfrom ?? m.from_name ?? m.from)},${csvEscape(m.text)}`);
        }
    }
    else {
        for (let i = 0; i < length(msgs); i++) {
            const m = msgs[i];
            push(reply, `${m.time ?? m.rx_time ?? m.id} ${m.textfrom ?? m.from_name ?? m.from ?? ""}: ${m.text ?? ""}`);
        }
    }
    event.queue({ cmd: "/reply", reply: reply, socket: id });
}

export function post(cmd, id, namekey)
{
    switch (cmd[0]) {
        case "join":
        {
            const parsed = groups.parseJoinArgs(slice(cmd, 1));
            if (!parsed) {
                event.queue({ cmd: "/reply", reply: [
                    "Usage:",
                    "/join #name &mdash; join/create shared-key channel (Meshtastic+MeshCore+AREDN)",
                    "/join %name &mdash; join/create AREDN-only channel",
                    "/join #name CALL1 CALL2 message &mdash; create APRS group + channel + send",
                    "/join #name backend=NAME CALL1 message &mdash; APRS group on specific backend"
                ], socket: id });
                break;
            }
            const namekey = groups.createGroupChannel(parsed.name, parsed.arednOnly, parsed.backendName);
            if (length(parsed.members) > 0) {
                groups.putGroup(parsed.name, parsed.members, {
                    backend: parsed.backendName,
                    repeat_member_messages: false,
                    rate_limit_seconds: 20,
                    max_members: 10
                });
                if (namekey && aprs.enabled) {
                    aprs.updateChannelBackend(namekey, parsed.backendName);
                }
                if (parsed.messageText && aprs.enabled) {
                    aprs.sendToGroup(groups.getGroup(parsed.name), parsed.messageText, namekey);
                }
                const reply = [
                    `Created group ${parsed.name} (${length(parsed.members)} member${length(parsed.members) > 1 ? "s" : ""})`,
                    `Channel: ${namekey}`
                ];
                if (parsed.backendName) {
                    push(reply, `Backend: ${parsed.backendName}`);
                }
                if (parsed.messageText) {
                    push(reply, `Sent: &ldquo;${parsed.messageText}&rdquo;`);
                }
                event.queue({ cmd: "/reply", reply: reply, socket: id });
            }
            else {
                event.queue({ cmd: "/reply", reply: [ `Joined channel ${parsed.name}` ], socket: id });
            }
            break;
        }
        case "leave":
        {
            const name = cmd[1];
            if (!name) {
                event.queue({ cmd: "/reply", reply: [ "Usage:", "/leave #name &mdash; leave channel and remove APRS group if present" ], socket: id });
                break;
            }
            groups.removeGroup(name);
            const currchannels = channel.getAllLocalChannels();
            const baseName = substr(name, 1);
            const newchannels = map(filter(currchannels, c => {
                const cn = split(c.namekey, " ")[0];
                const cnBase = substr(cn, 1);
                return cnBase !== baseName;
            }), c => {
                const s = textmessage.state(c.namekey);
                return { namekey: c.namekey, max: s.max, badge: s.badge, images: s.images, telemetry: c.telemetry, winlink: s.winlink, backend: c.backend ?? "" };
            });
            if (length(currchannels) !== length(newchannels)) {
                event.queue({ cmd: "newchannels", channels: newchannels });
                event.queue({ cmd: "/reply", reply: [ `Left ${name}` ], socket: id });
            }
            else {
                event.queue({ cmd: "/reply", reply: [ `Not in ${name}` ], socket: id });
            }
            break;
        }
        case "groups":
        {
            const all = groups.allGroups();
            if (length(all) === 0) {
                event.queue({ cmd: "/reply", reply: [ "No APRS groups defined" ], socket: id });
            }
            else {
                const reply = [ "APRS groups:", "&nbsp;" ];
                for (let i = 0; i < length(all); i++) {
                    const g = all[i];
                    const mems = join(", ", g.members ?? []);
                    const be = g.backend ? ` [backend=${g.backend}]` : "";
                    const rpt = g.repeat_member_messages ? " [repeat]" : "";
                    push(reply, `<b>${g.name}</b>${be}${rpt}: ${mems}`);
                }
                event.queue({ cmd: "/reply", reply: reply, socket: id });
            }
            break;
        }
        case "channels":
        {
            switch (cmd[1] ?? "local") {
                case "world":
                {
                    const bridge = getBridge();
                    if (bridge) {
                        router.queue(message.createMessage(bridge, null,null, "command", {
                            id: id,
                            cmd: "get_public_channels"
                        }, {
                            hop_limit: 0
                        }));
                        break;
                    }
                    // Fall through
                }
                case "local":
                {
                    const reply = [
                        "Public channels on local network", "&nbsp;",
                        ...getPublicChannels()
                    ];
                    event.queue({ cmd: "/reply", reply: reply, socket: id });
                    break;
                }
                case "join":
                {
                    const name = cmd[2];
                    let key;
                    if (ord(name) === 35) { // #
                        key = b64enc(struct.pack("16B", ...crypto.sha256hash(name)));
                    }
                    else if (ord(name) === 37) { // %
                        key = "og==";
                    }
                    else {
                        key = cmd[3];
                    }
                    if (name && key) {
                        let join = true;
                        const namekey = `${name} ${key}`;
                        const newchannel = { namekey: namekey, max: 100, badge: true, images: false, telemetry: false, winlink: false };
                        const currchannels = currentChannelsAsSettings();
                        for (let i = 0; i < length(currchannels); i++) {
                            if (currchannels[i].namekey === namekey) {
                                join = false;
                                break;
                            }
                        }
                        if (join) {
                            event.queue({ cmd: "newchannels", channels: [ ...currchannels, newchannel ] });
                            event.queue({ cmd: "/reply", reply: [ `Joined channel ${name}` ], socket: id });
                        }
                    }
                    break;
                }
                case "leave":
                {
                    if (cmd[2]) {
                        const name = `${cmd[2]} `;
                        const currchannels = channel.getAllLocalChannels();
                        const newchannels = map(filter(currchannels, c => index(c.namekey, name) !== 0), c => {
                            const s = textmessage.state(c.namekey);
                            return { namekey: c.namekey, max: s.max, badge: s.badge, images: s.images, telemetry: c.telemetry, winlink: s.winlink, backend: c.backend ?? "" };
                        });
                        if (length(currchannels) !== length(newchannels)) {
                            event.queue({ cmd: "newchannels", channels: newchannels });
                            event.queue({ cmd: "/reply", reply: [ `Left channel ${name}` ], socket: id });
                        }
                    }
                    break;
                }
                default:
                    break;
            }
            break;
        }
        case "export":
        {
            const fmt = lc(cmd[1] ?? "text");
            if (fmt !== "text" && fmt !== "csv") {
                event.queue({ cmd: "/reply", reply: [ "Usage:", "/export", "/export csv" ], socket: id });
            }
            else {
                exportMessages(id, namekey, fmt);
            }
            break;
        }
        case "backend":
        case "backends":
        {
            if (!aprs.enabled) {
                event.queue({ cmd: "/reply", reply: [ "APRS is not enabled" ], socket: id });
                break;
            }
            const bes = aprs.getBackendNames();
            if (length(bes) === 0) {
                event.queue({ cmd: "/reply", reply: [ "No APRS backends configured" ], socket: id });
            }
            else {
                const reply = [ "APRS backends:", "&nbsp;" ];
                for (let i = 0; i < length(bes); i++) {
                    push(reply, `<b>${bes[i].key}</b> &mdash; ${bes[i].label}`);
                }
                event.queue({ cmd: "/reply", reply: reply, socket: id });
            }
            break;
        }
        case "storage":
        {
            switch (cmd[1] ?? "status") {
                case "status":
                {
                    if (!storageSupported(id, "storageStatus")) {
                        break;
                    }
                    const s = platform.storageStatus();
                    const reply = [
                        `<b>Crow storage:</b> ${s.state}`,
                        `Mode: ${s.mode}`,
                        `Root: ${s.root}`,
                        `Images: ${s.image_root}`
                    ];
                    if (s.mountpoint) {
                        push(reply, `Mountpoint: ${s.mountpoint}`);
                    }
                    if (!s.usb_port) {
                        push(reply, "USB: no port on this device");
                    }
                    if (s.reason) {
                        push(reply, `Reason: ${s.reason}`);
                        push(reply, "Core service is still running from node storage; persistence may be limited until USB storage is restored.");
                    }
                    event.queue({ cmd: "/reply", reply: reply, socket: id });
                    break;
                }
                case "usb":
                {
                    switch (cmd[2] ?? "scan") {
                        case "scan":
                        {
                            if (!storageSupported(id, "storageScan")) {
                                break;
                            }
                            const candidates = platform.storageScan();
                            if (!candidates || length(candidates) === 0) {
                                event.queue({ cmd: "/reply", reply: [ "No removable USB storage candidates found." ], socket: id });
                                break;
                            }
                            const reply = [ "USB storage candidates:", "&nbsp;" ];
                            for (let i = 0; i < length(candidates); i++) {
                                const d = candidates[i];
                                push(reply, `<b>${d.device}</b> ${d.model ?? ""} ${fmtBytes(d.size_bytes)}${d.mounted ? " [mounted]" : ""}`);
                            }
                            event.queue({ cmd: "/reply", reply: reply, socket: id });
                            break;
                        }
                        case "enable":
                        case "mount":
                        {
                            if (!storageSupported(id, "storageMount")) {
                                break;
                            }
                            const result = platform.storageMount();
                            event.queue({ cmd: "/reply", reply: [ result.ok ? "USB storage active." : "USB storage degraded.", result.message ?? "" ], socket: id });
                            break;
                        }
                        case "disable":
                        {
                            if (!storageSupported(id, "storageDisable")) {
                                break;
                            }
                            const result = platform.storageDisable();
                            event.queue({ cmd: "/reply", reply: [ result.message ?? "Crow storage returned to internal node storage." ], socket: id });
                            break;
                        }
                        default:
                            event.queue({ cmd: "/reply", reply: [ "Usage:", "/storage usb scan", "/storage usb enable", "/storage usb disable" ], socket: id });
                            break;
                    }
                    break;
                }
                case "quota":
                {
                    if (cmd[2] === "images" && cmd[3]) {
                        if (!storageSupported(id, "storageImageQuota")) {
                            break;
                        }
                        const result = platform.storageImageQuota(+cmd[3]);
                        event.queue({ cmd: "/reply", reply: [ result.message ?? "Image quota updated." ], socket: id });
                    }
                    else {
                        event.queue({ cmd: "/reply", reply: [ "Usage: /storage quota images <mb>" ], socket: id });
                    }
                    break;
                }
                default:
                    event.queue({ cmd: "/reply", reply: [ "Usage:", "/storage status", "/storage usb scan", "/storage usb enable", "/storage usb disable", "/storage quota images <mb>" ], socket: id });
                    break;
            }
            break;
        }
        case "help":
        {
            event.queue({ cmd: "/reply", reply: [
                "<b>Crow Slash Commands</b>", "&nbsp;",
                "<b>/join</b> #name &mdash; join/create shared-key channel (Meshtastic+MeshCore+AREDN)",
                "<b>/join</b> %name &mdash; join/create AREDN-only channel",
                "<b>/join</b> #name CALL1 CALL2 message &mdash; create APRS group + channel + send message",
                "<b>/join</b> #name backend=NAME CALL1 msg &mdash; APRS group on a specific backend",
                "<b>/leave</b> #name &mdash; leave channel and remove APRS group",
                "<b>/groups</b> &mdash; list all APRS groups and members",
                "<b>/channels</b> &mdash; list public channels on local network",
                "<b>/channels world</b> &mdash; list public channels across the wider mesh",
                "<b>/channels join</b> #name | %name | Name key &mdash; join a channel",
                "<b>/channels leave</b> #name &mdash; leave a channel",
                "<b>/storage status</b> &mdash; show active storage state",
                "<b>/storage usb scan</b> &mdash; list removable USB devices",
                "<b>/storage usb enable</b> &mdash; mount/activate USB storage",
                "<b>/storage usb mount</b> &mdash; alias for enable",
                "<b>/storage usb disable</b> &mdash; return to internal node storage",
                "<b>/storage quota images</b> MB &mdash; set image quota",
                "<b>/export</b> &mdash; export selected channel as text",
                "<b>/export csv</b> &mdash; export selected channel as CSV",
                "<b>/backends</b> &mdash; list configured APRS backends"
            ], socket: id });
            break;
        }
        default:
            event.queue({ cmd: "/reply", reply: [ `Unknown command: <b>/${cmd[0]}</b>. Type <b>/help</b> for a list of commands.` ], socket: id });
            break;
    }
};

export function setup(config)
{
};

export function tick()
{
};

export function process(msg)
{
    if (msg.data?.command && node.toMe(msg)) {
        switch (msg.data.command.cmd) {
            case "get_public_channels":
            {
                router.queue(message.createMessage(msg.from, null,null, "command", {
                    id: msg.data.command.id,
                    cmd: "reply_public_channels",
                    channels: getPublicChannels(),
                }, {
                    hop_limit: 0
                }));
                break;
            }
            case "reply_public_channels":
            {
                const reply = [
                    "Public channels on world network", "&nbsp;",
                    ...msg.data.command.channels
                ];
                event.queue({ cmd: "/reply", reply: reply, socket: msg.data.command.id });
            }
            default:
                break;
        }
    }
};
