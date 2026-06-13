// New MeshCore KISS/TNC backend.
//
// This file is intentionally separate from meshcore.uc. The legacy UDP
// multicast bridge backend remains untouched while this backend is developed
// and tested side-by-side.

import * as socket from "socket";
import * as struct from "struct";
import * as timers from "timers";
import * as channel from "channel";
import * as node from "node";
import * as nodedb from "nodedb";
import * as kiss from "meshcore_tnc_kiss";
import * as pkt from "meshcore_tnc_packet";
import * as mccrypto from "meshcore_tnc_crypto";
import * as identity from "meshcore_tnc_identity";

const SAVE_INTERVAL = 19 * 60;
const ACK_INTERVAL = 60;
const DEFAULT_TCP_PORT = 8001;
const DEFAULT_BAUD = 115200;

const PAYLOAD_TYPE_TXT_MSG = 0x02;
const PAYLOAD_TYPE_ACK = 0x03;
const PAYLOAD_TYPE_ADVERT = 0x04;
const PAYLOAD_TYPE_GRP_TXT = 0x05;
const PAYLOAD_TYPE_PATH = 0x08;

const ADV_TYPE_CHAT = 1;
const ADV_TYPE_REPEATER = 2;
const ADV_TYPE_ROOM = 3;
const ADV_TYPE_SENSOR = 4;

const MAX_TEXT_MESSAGE_LENGTH = 150;

let h = null;
let kstate = kiss.createState();
let callsign = null;
let hashsize = 1;
let prefixHash1 = null;
let prefixHash2 = null;
let router = null;
let kissport = 0;
let cfg = null;
const pending = [];
const pendingAcks = {};
export let enabled = false;

function log0(fmt, ...args)
{
    DEBUG0("meshcore_tnc: " + fmt, ...args);
}

function sendDirect(msg)
{
    return node.fromMe(msg) && !node.isBroadcast(msg) && (!msg.namekey || channel.isDirect(msg.namekey));
}

function addToAckQ(to, from, id, checksum)
{
    pendingAcks[struct.pack("4B", ...checksum)] = { to: to, from: from, id: id, checksum: checksum, when: time(), retry: 0 };
}

function ackAck(checksumRaw)
{
    const ack = pendingAcks[checksumRaw];
    if (ack) {
        delete pendingAcks[checksumRaw];
    }
    return ack;
}

function processAcks()
{
    const when = time() - ACK_INTERVAL;
    for (let k in pendingAcks) {
        const ack = pendingAcks[k];
        if (ack.when < when) {
            nodedb.updatePath(ack.to, null);
            delete pendingAcks[k];
        }
    }
}

function openTcp(host, port)
{
    const s = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
    s.connect({ address: host, port: port });
    return s;
}

function openSerial(device, baud)
{
    // ucode/OpenWrt builds do not all expose the same serial API. If the
    // platform layer grows openSerial(), use it. Otherwise run a TCP bridge
    // such as ser2net/socat and configure meshcore_tnc.host/port.
    if (platform.openSerial) {
        return platform.openSerial(device, baud ?? DEFAULT_BAUD, "8N1");
    }
    log0("serial device %s requested but platform.openSerial() is not available; use TCP KISS bridge for now\n", device);
    return null;
}

export function setup(config)
{
    cfg = config.meshcore_tnc ?? config.meshcore?.tnc;
    if (!cfg || cfg.enabled === false) {
        return;
    }

    callsign = config.callsign;
    router = config.router;
    hashsize = cfg.hashsize ?? 1;
    kissport = cfg.kissport ?? 0;

    prefixHash1 = node.getMeshcoreHash(1);
    prefixHash2 = node.getMeshcoreHash(2);

    if (cfg.host) {
        h = openTcp(cfg.host, cfg.port ?? DEFAULT_TCP_PORT);
    }
    else if (cfg.device) {
        h = openSerial(cfg.device, cfg.baud ?? DEFAULT_BAUD);
    }

    if (!h && !cfg.shadow_only) {
        log0("no TNC handle available; backend disabled\n");
        return;
    }

    mccrypto.load();
    timers.setInterval("meshcore_tnc.save", SAVE_INTERVAL);
    timers.setInterval("meshcore_tnc.acks", ACK_INTERVAL);
    enabled = true;
};

export function shutdown()
{
    mccrypto.save();
};

export function handle()
{
    return h;
};

function readBytes()
{
    if (!h) {
        return null;
    }
    try {
        return h.recv(512);
    }
    catch (_) {
    }
    try {
        return h.read(512);
    }
    catch (_) {
    }
    try {
        return h.recvmsg(512).data;
    }
    catch (_) {
    }
    return null;
}

function writeBytes(data)
{
    if (!h || !data) {
        return false;
    }
    try {
        return h.send(data) !== null;
    }
    catch (_) {
    }
    try {
        return h.write(data) !== null;
    }
    catch (_) {
    }
    return false;
}

function baseMsg(parsed)
{
    return {
        id: parsed.id,
        from: node.UNKNOWN,
        to: node.UNKNOWN,
        hop_limit: 1,
        data: {},
        transport: "meshcore",
        backend: "tnc",
        originating_callsign: callsign,
        meshcore_payload_type: parsed.payload_type_name,
        meshcore_route_type: parsed.route_type_name,
        meshcore_path_hash_size: parsed.path_hash_size
    };
}

function decodeAdvert(parsed)
{
    const learned = identity.rememberAdvert(parsed);
    if (!learned) {
        return null;
    }
    const advert = parsed.advert.advert;
    const msg = baseMsg(parsed);
    msg.from = learned.id;
    msg.data.advert = {
        hw_model: 253,
        is_unmessagable: advert.role_type !== ADV_TYPE_CHAT,
        public_key: advert.public_key,
        timestamp: advert.timestamp,
        name: advert.name,
        position: advert.position
    };
    return identity.enrichMessageIdentity(msg);
}

function decodeText(parsed)
{
    const text = mccrypto.decryptTextMessage(parsed);
    if (!text) {
        return null;
    }
    const msg = baseMsg(parsed);
    msg.from = text.from;
    msg.to = text.to;
    msg.rx_time = text.rx_time;
    msg.attempt = text.attempt;
    msg.want_ack = true;
    msg.namekey = nodedb.namekey(text.from);
    msg.data.text_message = text.text_message;
    msg.data.checksum = text.checksum;
    msg.meshcore_signed_prefix_checked = text.signed_prefix_checked;
    return identity.enrichMessageIdentity(msg);
}

function decodeGroupText(parsed)
{
    const text = mccrypto.decryptGroupText(parsed);
    if (!text) {
        return null;
    }
    const msg = baseMsg(parsed);
    msg.from = text.from;
    msg.to = node.BROADCAST;
    msg.namekey = text.namekey;
    msg.rx_time = text.rx_time;
    msg.data.text_message = text.text_message;
    msg.data.text_from = text.text_from;
    msg.meshcore_weak_identity = text.weak_identity;
    return identity.enrichMessageIdentity(msg);
}

function decodeAck(parsed)
{
    const ack = ackAck(parsed.ack?.checksum_raw);
    if (!ack) {
        return null;
    }
    const msg = baseMsg(parsed);
    msg.to = ack.from;
    msg.from = ack.to;
    msg.data.routing = { error_reason: 0, checksum: ack.checksum };
    msg.data.request_id = ack.id;
    return msg;
}

export function decodeRaw(raw)
{
    const parsed = pkt.parse(raw);
    if (!parsed?.ok) {
        log0("drop bad raw packet: %s\n", parsed?.error ?? "parse failed");
        return null;
    }

    switch (parsed.payload_type) {
        case PAYLOAD_TYPE_ADVERT:
            return decodeAdvert(parsed);
        case PAYLOAD_TYPE_TXT_MSG:
            return decodeText(parsed);
        case PAYLOAD_TYPE_GRP_TXT:
            return decodeGroupText(parsed);
        case PAYLOAD_TYPE_ACK:
            return decodeAck(parsed);
        case PAYLOAD_TYPE_PATH:
            // PATH packets are parsed in the packet layer. The existing UDP
            // backend only turns PATH into a Crow routing message when it
            // carries an ACK. Keep this conservative until live tests prove the
            // exact TNC behavior.
            return null;
        default:
            return null;
    }
}

function processKissFrame(frame)
{
    if (kiss.isSetHardwareFrame(frame)) {
        DEBUG2("meshcore_tnc: ignore SetHardware frame len=%d\n", length(frame.data));
        return;
    }
    if (!kiss.isDataFrame(frame)) {
        DEBUG2("meshcore_tnc: ignore KISS command %d len=%d\n", frame.command, length(frame.data));
        return;
    }
    const msg = decodeRaw(frame.data);
    if (msg) {
        push(pending, msg);
    }
}

export function recv()
{
    if (length(pending) > 0) {
        return shift(pending);
    }

    const data = readBytes();
    if (!data) {
        return null;
    }

    const frames = kiss.feed(kstate, data);
    for (let i = 0; i < length(frames); i++) {
        processKissFrame(frames[i]);
    }

    if (length(pending) > 0) {
        return shift(pending);
    }
    return null;
}

function advertRoleType(role)
{
    switch (role) {
        case node.ROLE_REPEATER:
        case node.ROLE_CLIENT:
            return ADV_TYPE_REPEATER;
        case node.ROLE_ROOM:
            return ADV_TYPE_ROOM;
        case node.ROLE_SENSOR:
            return ADV_TYPE_SENSOR;
        case node.ROLE_CLIENT_MUTE:
        case node.ROLE_COMPANION:
        default:
            return ADV_TYPE_CHAT;
    }
}

function buildAdvertRaw(msg)
{
    const advert = msg.data.advert;
    const fromprivate = node.fromMe(msg) ? node.getInfo().private_key : platform.getTargetById(msg.from)?.private_key;
    if (!fromprivate) {
        return null;
    }
    const payload = pkt.buildAdvertPayload({
        public_key: advert.public_key,
        role_type: advertRoleType(advert.role),
        position: advert.position,
        name: advert.name
    }, fromprivate, msg.rx_time);
    return pkt.makePacketHeader(PAYLOAD_TYPE_ADVERT, null, hashsize, prefixHash1, prefixHash2) + payload;
}

function buildDirectTextRaw(msg)
{
    const enc = mccrypto.encryptDirectText(msg);
    if (!enc) {
        return null;
    }
    addToAckQ(msg.to, msg.from, msg.id, slice(crypto.sha256hash(enc.plain + enc.keys.frompublic), 0, 4));
    return pkt.makePacketHeader(PAYLOAD_TYPE_TXT_MSG, msg.path, hashsize, prefixHash1, prefixHash2) + enc.payload;
}

function buildGroupTextRaws(msg)
{
    const chan = channel.getChannelByNameKey(msg.namekey);
    if (!chan || length(chan.symmetrickey) !== 16) {
        return null;
    }
    const name = nodedb.getNode(msg.from, false)?.nodeinfo?.long_name ?? msg.data.text_from ?? `${msg.from}`;
    let text = `${name}: ${msg.data.text_message}`;
    const raws = [];

    if (length(text) <= MAX_TEXT_MESSAGE_LENGTH) {
        const payload = mccrypto.encryptGroupText(msg, chan, text);
        push(raws, pkt.makePacketHeader(PAYLOAD_TYPE_GRP_TXT, null, hashsize, prefixHash1, prefixHash2) + payload);
        return raws;
    }

    const words = split(msg.data.text_message, " ");
    let line = `${name}: ${words[0]}`;
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
            line = `${name}: ${words[i]}`;
        }
    }
    while (length(line) > 0) {
        push(lines, substr(line, 0, limit));
        line = substr(line, limit);
    }

    const lenlines = length(lines);
    for (let i = 0; i < lenlines; i++) {
        const payload = mccrypto.encryptGroupText(msg, chan, `${lines[i]} (${i + 1}/${lenlines})`);
        push(raws, pkt.makePacketHeader(PAYLOAD_TYPE_GRP_TXT, null, hashsize, prefixHash1, prefixHash2) + payload);
    }
    return raws;
}

function makeRawPackets(msg)
{
    if (node.isBroadcast(msg)) {
        msg.path = null;
    }
    else {
        msg.path = nodedb.getNode(msg.to, false)?.path;
    }

    if (msg.data?.advert) {
        const raw = buildAdvertRaw(msg);
        return raw ? [ raw ] : null;
    }

    if (msg.data?.text_message) {
        if (sendDirect(msg)) {
            const raw = buildDirectTextRaw(msg);
            return raw ? [ raw ] : null;
        }
        return buildGroupTextRaws(msg);
    }

    if (msg.data?.routing?.error_reason === 0 && msg.data.routing.checksum) {
        return [ pkt.makePacketHeader(PAYLOAD_TYPE_ACK, null, hashsize, prefixHash1, prefixHash2) + struct.pack("4B", ...msg.data.routing.checksum) ];
    }

    return null;
}

export function send(msg)
{
    if (!h) {
        return;
    }
    const raws = makeRawPackets(msg);
    if (!raws) {
        return;
    }
    for (let i = 0; i < length(raws); i++) {
        const frame = kiss.encodeData(raws[i], kissport);
        if (!writeBytes(frame)) {
            log0("send failed\n");
        }
    }
}

export function tick()
{
    if (timers.tick("meshcore_tnc.save")) {
        mccrypto.save();
    }
    if (timers.tick("meshcore_tnc.acks")) {
        processAcks();
    }
};

export function process(msg)
{
};
