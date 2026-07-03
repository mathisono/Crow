import * as struct from "struct";
import * as channel from "channel";
import * as router from "router";
import * as message from "message";
import * as textmessage from "textmessage";
import * as node from "node";
import * as crypto from "crypto.crypto";
import * as groups from "groups";
import * as aprs from "aprs";
import * as meshcore_backend from "meshcore_backend";
import * as meshtastic_backend from "meshtastic_backend";
import * as meshcore_discovery from "meshcore_tcp_discovery";
import * as gatekeeper from "gatekeeper";

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

function deriveKeyFromPassphrase(passphrase)
{
    return crypto.sha256hash(passphrase);
}

function keyBytesToBase64(keyBytes)
{
    let keyStr = "";
    for (let i = 0; i < length(keyBytes); i++) {
        keyStr += chr(keyBytes[i]);
    }
    return b64enc(keyStr);
}

function backendBadge(state)
{
    if (state === "connected" || state === "listening") {
        return "🟢";
    }
    if (state === "connecting") {
        return "🟡";
    }
    if (state === "waiting") {
        return "🟠";
    }
    if (state === "configured-inactive") {
        return "⚫";
    }
    if (state === "disconnected" || state === "enabled-no-socket") {
        return "🔴";
    }
    return "⚪";
}

function pushBackendStatus(reply, b)
{
    const state = b.state ?? (b.active ? "active" : "configured");
    const badge = backendBadge(state);
    const active = b.active ? " <i>(active)</i>" : "";

    push(reply, `${badge} <b>${b.key}</b> &mdash; ${b.label}${active}`);
    if (b.family) {
        push(reply, `Family: ${b.family}`);
    }
    if (b.transport) {
        push(reply, `Transport: ${b.transport}`);
    }
    push(reply, `State: ${state}`);
    if (exists(b, "host") && b.host !== null && exists(b, "port") && b.port !== null) {
        push(reply, `Target: ${b.host}:${b.port}`);
    }
    if (exists(b, "pending_rx")) {
        push(reply, `Pending RX: ${b.pending_rx}`);
    }
    if (b.reconnect_in_seconds > 0) {
        push(reply, `Reconnect in: ${b.reconnect_in_seconds}s`);
    }
    if (b.reconnect_delay_seconds > 0 && state !== "connected") {
        push(reply, `Retry delay: ${b.reconnect_delay_seconds}s`);
    }
    push(reply, "&nbsp;");
}

function backendStatusReply()
{
    const reply = [ "Backend status:", "&nbsp;" ];

    if (!aprs.enabled) {
        push(reply, "⚪ <b>aprs</b> &mdash; APRS is not enabled");
        push(reply, "&nbsp;");
    }
    else {
        const bes = aprs.getBackendStatus ? aprs.getBackendStatus() : aprs.getBackendNames();
        if (!bes || length(bes) === 0) {
            push(reply, "⚪ <b>aprs</b> &mdash; No APRS backends configured");
            push(reply, "&nbsp;");
        }
        else {
            for (let i = 0; i < length(bes); i++) {
                const b = bes[i];
                b.family = "aprs";
                if (substr(b.key ?? "", 0, 5) !== "aprs.") {
                    b.key = `aprs.${b.key}`;
                }
                pushBackendStatus(reply, b);
            }
        }
    }

    const meshcore = meshcore_backend.backendStatus ? meshcore_backend.backendStatus() : [];
    for (let i = 0; i < length(meshcore); i++) {
        pushBackendStatus(reply, meshcore[i]);
    }

    const meshtastic = meshtastic_backend.backendStatus ? meshtastic_backend.backendStatus() : [];
    for (let i = 0; i < length(meshtastic); i++) {
        pushBackendStatus(reply, meshtastic[i]);
    }

    return reply;
}

export function post(cmd, id)
{
    switch (cmd[0]) {
        case "join":
        {
            const parsed = groups.parseJoinArgs(slice(cmd, 1));
            if (!parsed) {
                event.queue({ cmd: "/reply", reply: [
                    "Usage:",
                    "/join #name &mdash; join/create shared-key channel (Meshtastic+MeshCore+AREDN)",
                    "/join #name key=passphrase &mdash; join with derived key from passphrase",
                    "/join %name &mdash; join/create AREDN-only channel",
                    "/join #name CALL1 CALL2 message &mdash; create APRS group + channel + send",
                    "/join #name backend=NAME CALL1 message &mdash; APRS group on specific backend"
                ], socket: id });
                break;
            }

            let keyDropUsed = false;
            if (parsed.keyDrop) {
                const derivedKeyBytes = deriveKeyFromPassphrase(parsed.keyDrop);
                const base64Key = keyBytesToBase64(derivedKeyBytes);
                parsed.symmetricKey = base64Key;
                keyDropUsed = true;
                DEBUG0("commands: key drop used for passphrase (not logged)\n");
            }

            const namekey = groups.createGroupChannel(parsed.name, parsed.arednOnly, parsed.backendName, parsed.symmetricKey);
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
                if (keyDropUsed) {
                    push(reply, "⚠️ <i>Key derived from passphrase (not stored)</i>");
                }
                if (parsed.messageText) {
                    push(reply, `Sent: &ldquo;${parsed.messageText}&rdquo;`);
                }
                event.queue({ cmd: "/reply", reply: reply, socket: id });
            }
            else {
                const reply = [ `Joined channel ${parsed.name}` ];
                if (keyDropUsed) {
                    push(reply, "⚠️ <i>Key derived from passphrase (not stored)</i>");
                }
                event.queue({ cmd: "/reply", reply: reply, socket: id });
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
        case "cmd":
        {
            switch (cmd[1]) {
                case "discover":
                {
                    const backend = cmd[2] ?? "all";
                    const reply = [ "<b>Discovered Channels</b>", "&nbsp;" ];

                    if (backend === "all" || backend === "meshcore") {
                        const groups_discovered = meshcore_discovery.getCachedGroups();
                        if (groups_discovered && length(groups_discovered) > 0) {
                            push(reply, "<b>═══ MeshCore Groups ═══</b>");
                            for (let i = 0; i < length(groups_discovered); i++) {
                                const g = groups_discovered[i];
                                push(reply, `<b>Slot ${g.slot}: ${g.name}</b> (${g.key_size ?? "?"}-byte key)`);
                                push(reply, `<div class="cj" onclick='cmd("/join ${g.name}")'>/join ${g.name}</div>`);
                            }
                            push(reply, "&nbsp;");
                        }
                    }

                    if (backend === "all" || backend === "meshtastic") {
                        const all_channels = channel.getAllChannelNamekeys();
                        let meshtastic_count = 0;
                        for (let i = 0; i < length(all_channels); i++) {
                            const nk = all_channels[i];
                            if (channel.isMeshtasticPreset(nk)) continue;
                            const parts = split(nk, " ");
                            if (ord(parts[0]) !== 35) continue;

                            if (meshtastic_count === 0) {
                                push(reply, "<b>═══ Meshtastic Channels ═══</b>");
                            }
                            meshtastic_count++;
                            push(reply, `<b>${parts[0]}</b>`);
                            push(reply, `<div class="cj" onclick='cmd("/join ${parts[0]}")'>/join ${parts[0]}</div>`);
                        }
                        if (meshtastic_count > 0) {
                            push(reply, "&nbsp;");
                        }
                    }

                    push(reply, "<b>═══ Summary ═══</b>");
                    const meshcore_groups = meshcore_discovery.getCachedGroups();
                    const mc_count = meshcore_groups ? length(meshcore_groups) : 0;
                    push(reply, `MeshCore: ${mc_count} discovered groups`);
                    push(reply, "");
                    push(reply, "<i>Use /join &lt;channel_name&gt; to join</i>");

                    event.queue({ cmd: "/reply", reply: reply, socket: id });
                    break;
                }
                case "info":
                {
                    const namekey = cmd[2];
                    if (!namekey) {
                        event.queue({ cmd: "/reply", reply: [ "Usage: /cmd info &lt;namekey&gt;" ], socket: id });
                        break;
                    }
                    const chan = channel.getChannelByNameKey(namekey);
                    if (!chan) {
                        event.queue({ cmd: "/reply", reply: [ `Channel not found: ${namekey}` ], socket: id });
                        break;
                    }
                    const reply = [
                        `<b>Channel:</b> ${chan.namekey}`,
                        `<b>Key size:</b> ${length(chan.symmetrickey)} bytes`,
                        `<b>Backend:</b> ${chan.backend ?? "unknown"}`,
                        `<b>Telemetry:</b> ${chan.telemetry ? "yes" : "no"}`
                    ];
                    if (exists(chan, "slot_index") && chan.slot_index !== null) {
                        push(reply, `<b>MeshCore Slot:</b> ${chan.slot_index}`);
                    }
                    event.queue({ cmd: "/reply", reply: reply, socket: id });
                    break;
                }
                default:
                {
                    event.queue({ cmd: "/reply", reply: [
                        "Usage:",
                        "/cmd discover — List all discovered channels",
                        "/cmd discover meshcore — MeshCore groups only",
                        "/cmd discover meshtastic — Meshtastic channels only",
                        "/cmd info &lt;namekey&gt; — Channel details"
                    ], socket: id });
                    break;
                }
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
                        router.queue(message.createMessage(bridge, null, null, "command", {
                            id: id,
                            cmd: "get_public_channels"
                        }, {
                            hop_limit: 0
                        }));
                        break;
                    }
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
                    if (ord(name) === 35) {
                        key = b64enc(struct.pack("16B", ...crypto.sha256hash(name)));
                    }
                    else if (ord(name) === 37) {
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
        case "backend":
        case "backends":
        {
            event.queue({ cmd: "/reply", reply: backendStatusReply(), socket: id });
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
                "<b>/backends</b> &mdash; show APRS, MeshCore, and Meshtastic backend status",
                "<b>/storage</b> status &mdash; show active storage state",
                "<b>/channels</b> &mdash; list public channels on local network"
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
                router.queue(message.createMessage(msg.from, null, null, "command", {
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
                break;
            }
            default:
                break;
        }
    }
};
