import * as struct from "struct";
import * as channel from "channel";
import * as router from "router";
import * as message from "message";
import * as textmessage from "textmessage";
import * as node from "node";
import * as crypto from "crypto.crypto";

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

function storageSupported(id, fn)
{
    if (!platform || !platform[fn]) {
        event.queue({ cmd: "/reply", reply: [ "Storage management is not supported on this platform." ], socket: id });
        return false;
    }
    return true;
}

export function post(cmd, id)
{
    switch (cmd[0]) {
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
                        const currchannels = map(channel.getAllLocalChannels(), c => {
                            const s = textmessage.state(c.namekey);
                            if (c.namekey === namekey) {
                                join = false;
                            }
                            return { namekey: c.namekey, max: s.max, badge: s.badge, images: s.images, telemetry: c.telemetry, winlink: s.winlink };
                        });
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
                            return { namekey: c.namekey, max: s.max, badge: s.badge, images: s.images, telemetry: c.telemetry, winlink: s.winlink };
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
        default:
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
