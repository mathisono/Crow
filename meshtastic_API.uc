import * as socket from "socket";
import * as math from "math";
import * as struct from "struct";
import * as protobuf from "protobuf";
import * as crypto from "crypto.crypto";
import * as channel from "channel";
import * as node from "node";
import * as nodedb from "nodedb";
import * as timers from "timers";
import * as fs from "fs";

const DEFAULT_PORT = 4403;
const PORTAPI_MAGIC0 = 0x94;
const PORTAPI_MAGIC1 = 0xc3;
const PORTAPI_MAX_FRAME = 8192;
const SAVE_INTERVAL = 19 * 60; // 19 minutes
const RECONNECT_INTERVAL = 15;
const DEFAULT_CHANNEL_REFRESH = 600;
const BITFIELD_MQTT_OKAY = 1;
const TRANSPORT_MECHANISM_TCP = 8;
const MAX_TEXT_MESSAGE_LENGTH = 200;

const FROMRADIO_PACKET_TAG = 0x12;
const FROMRADIO_CONFIG_COMPLETE_ID_TAG = 0x38;
const FROMRADIO_CHANNEL_TAG = 0x52;
const TORADIO_PACKET_TAG = 0x0a;
const TORADIO_WANT_CONFIG_ID_TAG = 0x18;
const CHANNEL_INDEX_TAG = 0x08;
const CHANNEL_SETTINGS_TAG = 0x12;
const CHANNEL_SETTINGS_NAME_TAG = 0x1a;
const CHANNEL_SETTINGS_PSK_TAG = 0x22;

let s = null;
let cfg = null;
let tcpHost = null;
let tcpPort = DEFAULT_PORT;
let tcpbuf = "";
const pendingRx = [];

const portnum2Proto = {};
const proto2Portnum = {};
const protos = {};
let router;
let gatekeeper = null;
let callsign = null;
let dirty = false;
let builtinProtos = false;
let channelDiscovery = false;
let channelSync = "off";
let channelRefreshSeconds = DEFAULT_CHANNEL_REFRESH;
let lastConfigRequestId = 0;
let configRequestSeq = 0;
let discoveredChannels = {};
let stats = {
    connects: 0,
    disconnects: 0,
    bytes_rx: 0,
    frames_in: 0,
    frames_decoded: 0,
    config_requests: 0,
    config_complete: 0,
    channels_discovered: 0,
    channels_updated: 0,
    sends_ok: 0,
    sends_failed: 0
};
export let enabled = false;

export function registerProto(name, portnum, decode)
{
    protobuf.registerProto(protos, name, decode);
    if (portnum) {
        portnum2Proto[portnum] = name;
        proto2Portnum[name] = portnum;
    }
};

function registerBuiltinProtos()
{
    if (builtinProtos) {
        return;
    }
    builtinProtos = true;

    registerProto("packet", null, {
        "1": "fixed32 from",
        "2": "fixed32 to",
        "3": "uint32 channel",
        "4": "bytes decoded",
        "5": "bytes encrypted",
        "6": "fixed32 id",
        "7": "fixed32 rx_time",
        "8": "float rx_snr",
        "9": "uint32 hop_limit",
        "10": "bool want_ack",
        "11": "enum priority",
        "12": "int32 rx_rssi",
        "13": "enum delayed",
        "14": "bool via_mqtt",
        "15": "uint32 hop_start",
        "16": "bytes public_key",
        "17": "bool pki_encrypted",
        "18": "uint32 next_hop",
        "19": "uint32 relay_node",
        "20": "uint32 tx_after",
        "21": "enum transport_mechanism"
    });
    registerProto("channelsettings", null, {
        "3": "string name",
        "4": "bytes psk"
    });
    registerProto("channel", null, {
        "1": "uint32 index",
        "2": "proto channelsettings settings"
    });
    registerProto("fromradio", null, {
        "2": "proto packet packet",
        "7": "uint32 config_complete_id",
        "10": "proto channel channel"
    });
    registerProto("toradio", null, {
        "1": "proto packet packet",
        "3": "uint32 want_config_id"
    });
    registerProto("data", null, {
        "1": "enum portnum",
        "2": "bytes payload",
        "3": "bool want_response",
        "4": "fixed32 dest",
        "5": "fixed32 source",
        "6": "fixed32 request_id",
        "7": "fixed32 reply_id",
        "8": "fixed32 emoji",
        "9": "uint32 bitfield"
    });
}

let sharedKeys = {};

function log0(fmt, ...args)
{
    DEBUG0("meshtastic_API: " + fmt, ...args);
}

function log1(fmt, ...args)
{
    DEBUG1("meshtastic_API: " + fmt, ...args);
}

function log2(fmt, ...args)
{
    DEBUG2("meshtastic_API: " + fmt, ...args);
}

function notifyOperator(lines, mergekey)
{
    try {
        if (global.event?.queue) {
            global.event.queue({ cmd: "/reply", reply: lines });
        }
        if (global.event?.notify) {
            global.event.notify({ cmd: "channels" }, mergekey ?? "channels");
        }
    }
    catch (_) {
    }
}

function notifyChannelDiscovered(ch, action)
{
    const verb = action === "updated" ? "updated" : "discovered";
    notifyOperator([
        `<b>Meshtastic TCP API</b> ${verb} channel`,
        `Index ${ch.index}: ${ch.name}`,
        `Runtime only; not saved to Crow config.`
    ], `meshtastic-api-channel-${ch.index}`);
}

function getSharedKey(priv, pub)
{
    const hkey = `${priv}${pub}`;
    let sharedkey = sharedKeys[hkey];
    if (!sharedkey) {
        sharedkey = crypto.getSharedKey(priv, pub);
        sharedKeys[hkey] = sharedkey;
        dirty = true;
    }
    return sharedkey;
}

function loadSharedKeys()
{
    const data = platform.load("meshtastic.sharedkeys");
    if (data) {
        sharedKeys = data.sharedKeys;
    }
}

function saveSharedKeys()
{
    if (dirty) {
        platform.store("meshtastic.sharedkeys", {
            sharedKeys: sharedKeys
        });
        dirty = false;
    }
}

function sendDirect(msg)
{
    return node.fromMe(msg) && !node.isBroadcast(msg) && (!msg.namekey || channel.isDirect(msg.namekey));
}

function recvDirect(msg)
{
    return node.forMe(msg) && !msg.channel;
}

function looksDirect(msg)
{
    return msg && !node.isBroadcast(msg) && !msg.channel;
}

function merge(to, from)
{
    for (let k in from) {
        if (!(k in to)) {
            to[k] = from[k];
        }
    }
    return to;
}

function closeSocket(reason)
{
    if (s) {
        log0("disconnect %s\n", reason ?? "");
        stats.disconnects++;
        try {
            s.close();
        }
        catch (_) {
        }
    }
    s = null;
    tcpbuf = "";
}

function openTcp()
{
    if (!tcpHost) {
        log0("tcp host not configured; backend disabled\n");
        return null;
    }
    try {
        const ns = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
        ns.connect({ address: tcpHost, port: tcpPort });
        log0("connected tcp-port-api %s:%d\n", tcpHost, tcpPort);
        stats.connects++;
        return ns;
    }
    catch (_) {
        log0("tcp connect failed %s:%d: %s\n", tcpHost, tcpPort, socket.error());
        return null;
    }
}

function portApiFrame(payload)
{
    return chr(PORTAPI_MAGIC0) + chr(PORTAPI_MAGIC1) + chr((length(payload) >> 8) & 255) + chr(length(payload) & 255) + payload;
}

function extractPortApiFrames(data)
{
    const frames = [];
    tcpbuf += data;

    for (;;) {
        let start = -1;
        for (let i = 0; i + 1 < length(tcpbuf); i++) {
            if (ord(tcpbuf, i) === PORTAPI_MAGIC0 && ord(tcpbuf, i + 1) === PORTAPI_MAGIC1) {
                start = i;
                break;
            }
        }
        if (start < 0) {
            if (length(tcpbuf) > 1) {
                tcpbuf = substr(tcpbuf, -1);
            }
            return frames;
        }
        if (start > 0) {
            tcpbuf = substr(tcpbuf, start);
        }
        if (length(tcpbuf) < 4) {
            return frames;
        }
        const flen = (ord(tcpbuf, 2) << 8) + ord(tcpbuf, 3);
        if (flen > PORTAPI_MAX_FRAME) {
            log0("drop oversized Port-API frame len=%d\n", flen);
            tcpbuf = substr(tcpbuf, 2);
            continue;
        }
        if (length(tcpbuf) < flen + 4) {
            return frames;
        }
        push(frames, substr(tcpbuf, 4, flen));
        tcpbuf = substr(tcpbuf, flen + 4);
    }
}

function encodeVarint(v)
{
    let out = "";
    v = v ?? 0;
    for (;;) {
        let b = v & 0x7f;
        v = v >> 7;
        if (v) {
            out += chr(b | 0x80);
        }
        else {
            out += chr(b);
            return out;
        }
    }
}

function readVarint(buf, off)
{
    let value = 0;
    let shift = 0;
    for (let i = 0; i < 10; i++) {
        if (off + i >= length(buf)) {
            log2("tlv: truncated varint at off=%d\n", off);
            return null;
        }
        const b = ord(buf, off + i);
        value |= (b & 0x7f) << shift;
        if (!(b & 0x80)) {
            return { value: value, off: off + i + 1 };
        }
        shift += 7;
    }
    log2("tlv: overlong varint at off=%d\n", off);
    return null;
}

function readLenDelimited(buf, off)
{
    const l = readVarint(buf, off);
    if (!l) {
        return null;
    }
    if (l.value < 0 || l.off + l.value > length(buf)) {
        log2("tlv: bad length-delimited field off=%d len=%d remaining=%d\n", off, l.value, length(buf) - l.off);
        return null;
    }
    return { data: substr(buf, l.off, l.value), off: l.off + l.value, len: l.value };
}

function skipField(buf, off, wire_type)
{
    switch (wire_type) {
        case 0:
        {
            const v = readVarint(buf, off);
            return v ? v.off : null;
        }
        case 2:
        {
            const d = readLenDelimited(buf, off);
            return d ? d.off : null;
        }
        default:
            log2("tlv: unsupported wire type %d at off=%d\n", wire_type, off);
            return null;
    }
}

function decodeChannelSettings(buf)
{
    let off = 0;
    let name = null;
    let psk = null;

    while (off < length(buf)) {
        const k = readVarint(buf, off);
        if (!k) {
            return { name: name, psk: psk };
        }
        off = k.off;
        const tag = k.value;
        const wire = tag & 7;

        if (tag === CHANNEL_SETTINGS_NAME_TAG && wire === 2) {
            const d = readLenDelimited(buf, off);
            if (!d) {
                return { name: name, psk: psk };
            }
            name = d.data;
            off = d.off;
        }
        else if (tag === CHANNEL_SETTINGS_PSK_TAG && wire === 2) {
            const d = readLenDelimited(buf, off);
            if (!d) {
                return { name: name, psk: psk };
            }
            psk = d.data;
            off = d.off;
        }
        else {
            const noff = skipField(buf, off, wire);
            if (noff === null) {
                return { name: name, psk: psk };
            }
            log2("tlv: skip channelsettings tag=0x%02x wire=%d len=%d\n", tag, wire, noff - off);
            off = noff;
        }
    }
    return { name: name, psk: psk };
}

function decodeChannelProto(buf)
{
    let off = 0;
    let index = null;
    let settings = null;

    while (off < length(buf)) {
        const k = readVarint(buf, off);
        if (!k) {
            break;
        }
        off = k.off;
        const tag = k.value;
        const wire = tag & 7;

        if (tag === CHANNEL_INDEX_TAG && wire === 0) {
            const v = readVarint(buf, off);
            if (!v) {
                break;
            }
            index = v.value;
            off = v.off;
        }
        else if (tag === CHANNEL_SETTINGS_TAG && wire === 2) {
            const d = readLenDelimited(buf, off);
            if (!d) {
                break;
            }
            settings = decodeChannelSettings(d.data);
            off = d.off;
        }
        else {
            const noff = skipField(buf, off, wire);
            if (noff === null) {
                break;
            }
            log2("tlv: skip channel tag=0x%02x wire=%d len=%d\n", tag, wire, noff - off);
            off = noff;
        }
    }

    const name = settings?.name;
    const psk = settings?.psk;
    if (index === null || !name || !psk) {
        return null;
    }
    if (length(name) === 0 || length(psk) === 0) {
        return null;
    }
    const psk_b64 = b64enc(psk);
    return {
        index: index,
        name: name,
        psk: psk,
        psk_b64: psk_b64,
        namekey: `${name} ${psk_b64}`
    };
}

function extractChannels(buf)
{
    const channels = [];
    let off = 0;

    while (off < length(buf)) {
        const k = readVarint(buf, off);
        if (!k) {
            return channels;
        }
        off = k.off;
        const tag = k.value;
        const wire = tag & 7;

        if (tag === FROMRADIO_CHANNEL_TAG && wire === 2) {
            const d = readLenDelimited(buf, off);
            if (!d) {
                return channels;
            }
            const ch = decodeChannelProto(d.data);
            if (ch) {
                push(channels, ch);
            }
            off = d.off;
        }
        else {
            const noff = skipField(buf, off, wire);
            if (noff === null) {
                return channels;
            }
            log2("tlv: skip fromradio tag=0x%02x wire=%d len=%d\n", tag, wire, noff - off);
            off = noff;
        }
    }
    return channels;
}

function extractConfigCompleteId(buf)
{
    let off = 0;
    let id = null;
    while (off < length(buf)) {
        const k = readVarint(buf, off);
        if (!k) {
            return id;
        }
        off = k.off;
        const tag = k.value;
        const wire = tag & 7;
        if (tag === FROMRADIO_CONFIG_COMPLETE_ID_TAG && wire === 0) {
            const v = readVarint(buf, off);
            if (!v) {
                return id;
            }
            id = v.value;
            off = v.off;
        }
        else {
            const noff = skipField(buf, off, wire);
            if (noff === null) {
                return id;
            }
            off = noff;
        }
    }
    return id;
}

function channelFingerprint(psk)
{
    const h = crypto.sha256hash(psk);
    return b64enc(substr(h, 0, 4));
}

function updateDiscoveredChannel(ch)
{
    if (!ch || ch.index === null || !ch.name || !ch.psk) {
        return;
    }
    const key = `${ch.index}`;
    const old = discoveredChannels[key];
    const fp = channelFingerprint(ch.psk);
    if (!old) {
        discoveredChannels[key] = ch;
        stats.channels_discovered++;
        log1("channel discovered index=%d name=%s pskfp=%s\n", ch.index, ch.name, fp);
        notifyChannelDiscovered(ch, "discovered");
    }
    else if (old.name !== ch.name || old.psk_b64 !== ch.psk_b64) {
        discoveredChannels[key] = ch;
        stats.channels_updated++;
        log1("channel updated index=%d name=%s pskfp=%s\n", ch.index, ch.name, fp);
        notifyChannelDiscovered(ch, "updated");
    }
}

function processDiscoveredChannels(buf)
{
    const chans = extractChannels(buf);
    for (let i = 0; i < length(chans); i++) {
        updateDiscoveredChannel(chans[i]);
    }
    const complete = extractConfigCompleteId(buf);
    if (complete !== null) {
        stats.config_complete++;
        log1("config complete id=%d last_request=%d\n", complete, lastConfigRequestId);
    }
    return length(chans) > 0 || complete !== null;
}

export function _test_reset_discovery()
{
    discoveredChannels = {};
    stats.channels_discovered = 0;
    stats.channels_updated = 0;
    stats.config_complete = 0;
};

export function _test_process_discovered_channels(buf)
{
    return processDiscoveredChannels(buf ?? "");
};

export function _test_stats()
{
    return stats;
};

function buildWantConfigId(id)
{
    return portApiFrame(chr(TORADIO_WANT_CONFIG_ID_TAG) + encodeVarint(id));
}

function requestConfig(reason)
{
    if (!channelDiscovery || !s) {
        return false;
    }
    configRequestSeq = (configRequestSeq + 1) & 0x7fffffff;
    if (!configRequestSeq) {
        configRequestSeq = 1;
    }
    lastConfigRequestId = configRequestSeq;
    const r = writeSocket(buildWantConfigId(lastConfigRequestId));
    if (r) {
        stats.config_requests++;
        log1("config request sent id=%d reason=%s\n", lastConfigRequestId, reason ?? "unknown");
    }
    else {
        log0("config request failed id=%d reason=%s\n", lastConfigRequestId, reason ?? "unknown");
    }
    return r;
}

function decodePacketData(msg)
{
    if (msg.decoded) {
        const data = protobuf.decode(protos, "data", msg.decoded);
        if (data && data.portnum !== null && data.payload && data.bitfield !== null) {
            delete msg.decoded;
            if (data.portnum === 1) {
                data.text_message = data.payload;
                delete data.payload;
                msg.data = data;
                return msg;
            }
            const protoname = portnum2Proto[`${data.portnum}`];
            if (protoname) {
                data[protoname] = protobuf.decode(protos, protoname, data.payload);
                if (data[protoname]) {
                    delete data.payload;
                    msg.data = data;
                    return msg;
                }
            }
        }
    }
    return null;
}

function markLocalDirect(msg)
{
    if (looksDirect(msg)) {
        msg.metadata = merge({ local_direct: true }, msg.metadata ?? {});
    }
    return msg;
}

function decodePacketObject(msg)
{
    if (!msg) {
        return null;
    }
    msg.hop_limit = 1;
    msg.transport = "meshtastic";
    msg.backend = "tcp-port-api";
    msg.originating_callsign = callsign;
    markLocalDirect(msg);

    if (gatekeeper?.isEnabled() && msg.encrypted) {
        DEBUG0("gatekeeper: drop encrypted Meshtastic API packet from %s\n", msg.from);
        return null;
    }

    if (!msg.encrypted) {
        return decodePacketData(msg);
    }
    if (recvDirect(msg)) {
        const frompublic = nodedb.getNode(msg.from)?.nodeinfo?.public_key;
        const toprivate = node.toMe(msg) ? node.getInfo().private_key : platform.getTargetById(msg.to)?.private_key;
        if (frompublic && toprivate) {
            const sharedkey = getSharedKey(toprivate, frompublic);
            const hash = crypto.sha256hash(sharedkey);
            const ciphertext = substr(msg.encrypted, 0, -12);
            const auth = substr(msg.encrypted, -12, 8);
            const xnonce = substr(msg.encrypted, -4);
            msg.decoded = crypto.decryptCCM(msg.from, msg.id, hash, ciphertext, xnonce, auth);
            msg.namekey = nodedb.namekey(msg.from);
            if (decodePacketData(msg)) {
                delete msg.encrypted;
                return msg;
            }
        }
    }
    else {
        const hashchannels = channel.getChannelsByMeshtasticHash(msg.channel);
        if (hashchannels) {
            for (let i = 0; i < length(hashchannels); i++) {
                const chan = hashchannels[i];
                msg.decoded = crypto.decryptCTR(msg.from, msg.id, chan.symmetrickey, msg.encrypted);
                msg.namekey = chan.namekey;
                if (decodePacketData(msg)) {
                    delete msg.encrypted;
                    return msg;
                }
            }
        }
    }
    log0("drop unsupported/encrypted packet from %s id=%s\n", msg.from, msg.id);
    return null;
}

function decodePacket(pkt)
{
    return decodePacketObject(protobuf.decode(protos, "packet", pkt));
}

function decodeFromRadio(payload)
{
    if (processDiscoveredChannels(payload)) {
        return null;
    }

    const fromradio = protobuf.decode(protos, "fromradio", payload);
    if (fromradio?.packet) {
        return decodePacketObject(fromradio.packet);
    }
    return decodePacket(payload);
}

function encodePacket(msg)
{
    const direct = sendDirect(msg);
    const data = msg.data;
    if (data.text_message) {
        data.portnum = 1;
        data.payload = substr(data.text_message, 0, MAX_TEXT_MESSAGE_LENGTH);
        delete data.text_message;
    }
    else {
        for (let protoname in proto2Portnum) {
            if (data[protoname]) {
                data.portnum = proto2Portnum[protoname];
                data.payload = protobuf.encode(protos, protoname, data[protoname]);
                delete data[protoname];
                break;
            }
        }
    }
    if (!data.payload) {
        return null;
    }
    msg.decoded = protobuf.encode(protos, "data", msg.data);
    delete msg.data;
    if (direct) {
        delete msg.channel;
        const topublic = nodedb.getNode(msg.to)?.nodeinfo?.public_key;
        const fromprivate = node.fromMe(msg) ? node.getInfo().private_key : platform.getTargetById(msg.from)?.private_key;
        if (topublic && fromprivate) {
            const sharedkey = getSharedKey(fromprivate, topublic);
            const hash = crypto.sha256hash(sharedkey);
            const xnonce = struct.pack("4B", math.rand() & 255, math.rand() & 255, math.rand() & 255, math.rand() & 255);
            msg.encrypted = crypto.encryptCCM(msg.from, msg.id, hash, msg.decoded, xnonce, 8) + xnonce;
            delete msg.decoded;
            return protobuf.encode(protos, "packet", msg);
        }
    }
    else {
        const chan = channel.getChannelByNameKey(msg.namekey);
        if (chan) {
            msg.encrypted = crypto.encryptCTR(msg.from, msg.id, chan.symmetrickey, msg.decoded);
            delete msg.decoded;
            return protobuf.encode(protos, "packet", msg);
        }
    }
    return null;
}

function encodeToRadio(pkt)
{
    const packet = protobuf.decode(protos, "packet", pkt);
    if (!packet) {
        return null;
    }
    return portApiFrame(protobuf.encode(protos, "toradio", { packet: packet }));
}

export function setup(config)
{
    cfg = config.meshtastic_api ?? config.meshtastic_API;
    if (!cfg || cfg.enabled === false) {
        return;
    }
    registerBuiltinProtos();
    enabled = true;

    callsign = config.callsign;
    router = config.router;
    gatekeeper = config._gatekeeper;
    tcpHost = cfg.host;
    tcpPort = cfg.port ?? DEFAULT_PORT;
    channelDiscovery = !!cfg.channel_discovery;
    channelSync = cfg.channel_sync ?? "off";
    channelRefreshSeconds = cfg.channel_refresh_seconds ?? DEFAULT_CHANNEL_REFRESH;

    // Optional auto-channel injection: mirrors meshcore_tcp_api pattern.
    // Requires an explicit device_name (label prefix) and channel_name (goes into namekey,
    // since Meshtastic hashes from the channel-name portion). channel_key defaults to
    // LongFast public PSK "AQ==".
    const devName = cfg.device_name;
    const autoChan = cfg.channel_name;
    if (devName && autoChan) {
        const autoKey = cfg.channel_key ?? "AQ==";
        const autoNamekey = `${autoChan} ${autoKey}`;
        let hostname = "";
        try {
            const h = fs.readfile("/proc/sys/kernel/hostname");
            if (h) hostname = replace(h, "\n", "");
        } catch (e) {}
        const autoLabel = hostname
            ? `${hostname} · ${devName} · ${autoChan}`
            : `${devName} · ${autoChan}`;
        if (!config.channels) config.channels = [];
        let found = false;
        for (let i = 0; i < length(config.channels); i++) {
            if (config.channels[i].namekey === autoNamekey) {
                config.channels[i].label = autoLabel;
                found = true;
                break;
            }
        }
        if (!found) {
            push(config.channels, { namekey: autoNamekey, label: autoLabel });
        }
        log0("channel registered: %s (label: %s)\n", autoNamekey, autoLabel);
    }

    if (channelSync !== "off" && channelSync !== "read_only") {
        log0("unsupported channel_sync mode %s; forcing off\n", channelSync);
        channelSync = "off";
    }

    s = openTcp();
    if (s && channelDiscovery) {
        requestConfig("connect");
    }
    timers.setInterval("meshtastic_API.reconnect", RECONNECT_INTERVAL);
    loadSharedKeys();
    timers.setInterval("meshtastic_API.save", SAVE_INTERVAL);
    if (channelDiscovery) {
        timers.setInterval("meshtastic_API.channel_refresh", channelRefreshSeconds);
    }
};

export function shutdown()
{
    saveSharedKeys();
    closeSocket("shutdown");
};

export function handle()
{
    return s;
};

function makeNativeMsg(data)
{
    const frames = extractPortApiFrames(data);
    stats.frames_in += length(frames);
    for (let i = 0; i < length(frames); i++) {
        const msg = decodeFromRadio(frames[i]);
        if (msg) {
            stats.frames_decoded++;
            push(pendingRx, msg);
        }
    }
    if (length(pendingRx) > 0) {
        return shift(pendingRx);
    }
    return null;
}

function makeMeshtasticMsg(msg)
{
    let mchannel = null;
    if (node.isBroadcast(msg)) {
        const chan = channel.getChannelByNameKey(msg.namekey);
        if (!chan) {
            return null;
        }
        mchannel = chan.meshtastichash;
    }
    if (msg.data.text_message && length(msg.data.text_message) > MAX_TEXT_MESSAGE_LENGTH) {
        const words = split(msg.data.text_message, " ");
        let line = words[0];
        const lines = [];
        const limit = MAX_TEXT_MESSAGE_LENGTH - 8;
        for (let i = 1; i < length(words); i++) {
            if (length(line) >= limit) {
                push(lines, substr(line, 0, limit));
                line = substr(line, limit);
                i--;
            }
            else if (length(line) + length(words[i]) < limit) {
                line += " " + words[i];
            }
            else {
                push(lines, line);
                line = words[i];
            }
        }
        while (length(line) > 0) {
            push(lines, substr(line, 0, limit));
            line = substr(line, limit);
        }
        const lenlines = length(lines);
        const pkts = [];
        for (let i = 0; i < lenlines; i++) {
            const line = `${lines[i]} (${i + 1}/${lenlines})`;
            push(pkts, encodePacket(merge({
                rx_snr: 0,
                rx_rssi: 0,
                relay_node: msg.from & 255,
                transport_mechanism: TRANSPORT_MECHANISM_TCP,
                hop_start: msg.hop_limit,
                channel: mchannel,
                data:{
                    bitfield: BITFIELD_MQTT_OKAY,
                    text_message: line
                }
            }, msg)));
            router.queueId(msg.id);
            msg.id++;
        }
        return pkts;
    }
    return [ encodePacket(merge({
        rx_snr: 0,
        rx_rssi: 0,
        relay_node: msg.from & 255,
        transport_mechanism: TRANSPORT_MECHANISM_TCP,
        hop_start: msg.hop_limit,
        channel: mchannel,
        data: merge({
            bitfield: BITFIELD_MQTT_OKAY
        }, msg.data)
    }, msg)) ];
}

function readSocket()
{
    if (!s) {
        return null;
    }
    try {
        const data = s.recv(2048);
        if (data) {
            stats.bytes_rx += length(data);
        }
        return data;
    }
    catch (_) {
        closeSocket(socket.error());
        return null;
    }
}

export function recv()
{
    if (length(pendingRx) > 0) {
        return shift(pendingRx);
    }
    const data = readSocket();
    if (!data) {
        return null;
    }
    return makeNativeMsg(data);
};

function writeSocket(data)
{
    if (!s || !data) {
        return false;
    }
    try {
        return s.send(data) !== null;
    }
    catch (_) {
        closeSocket(socket.error());
        return false;
    }
}

export function send(msg)
{
    if (s !== null) {
        const pkts = makeMeshtasticMsg(msg);
        if (pkts && pkts[0]) {
            for (let i = 0; i < length(pkts); i++) {
                const data = encodeToRadio(pkts[i]);
                const r = writeSocket(data);
                if (!r) {
                    stats.sends_failed++;
                    log0("send error: %s\n", socket.error());
                }
                else {
                    stats.sends_ok++;
                    log0("send ok id=%s\n", msg.id);
                }
            }
        }
    }
    else {
        stats.sends_failed++;
        log0("send drop: tcp disconnected\n");
    }
};

export function tick()
{
    if (timers.tick("meshtastic_API.save")) {
        saveSharedKeys();
    }
    if (!s && timers.tick("meshtastic_API.reconnect")) {
        s = openTcp();
        if (s && channelDiscovery) {
            requestConfig("connect");
        }
    }
    if (s && channelDiscovery && timers.tick("meshtastic_API.channel_refresh")) {
        requestConfig("refresh");
    }
};

export function process(msg)
{
};

export function pending()
{
    return length(pendingRx);
};

export function status()
{
    return {
        connects: stats.connects,
        disconnects: stats.disconnects,
        bytes_rx: stats.bytes_rx,
        frames_in: stats.frames_in,
        frames_decoded: stats.frames_decoded,
        pending_rx: length(pendingRx),
        config_requests: stats.config_requests,
        config_complete: stats.config_complete,
        channels_discovered: stats.channels_discovered,
        channels_updated: stats.channels_updated,
        sends_ok: stats.sends_ok,
        sends_failed: stats.sends_failed,
        channel_discovery: channelDiscovery,
        channel_sync: channelSync
    };
};

// TODO future write support, deliberately not implemented in this read-only pass:
// - encodeChannelProto(index, name, psk)
// - admin/channel-set request
// - firmware compatibility testing
// - ACK/config-complete verification
// - operator confirmation before changing radio config
