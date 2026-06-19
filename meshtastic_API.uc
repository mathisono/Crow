import * as socket from "socket";
import * as math from "math";
import * as struct from "struct";
import * as protobuf from "protobuf";
import * as crypto from "crypto.crypto";
import * as channel from "channel";
import * as node from "node";
import * as nodedb from "nodedb";
import * as timers from "timers";

const DEFAULT_PORT = 4403;
const PORTAPI_MAGIC0 = 0x94;
const PORTAPI_MAGIC1 = 0xc3;
const PORTAPI_MAX_FRAME = 8192;
const SAVE_INTERVAL = 19 * 60; // 19 minutes
const RECONNECT_INTERVAL = 15;
const BITFIELD_MQTT_OKAY = 1;
const TRANSPORT_MECHANISM_TCP = 8;
const MAX_TEXT_MESSAGE_LENGTH = 200;

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
export let enabled = false;

export function registerProto(name, portnum, decode)
{
    protobuf.registerProto(protos, name, decode);
    if (portnum) {
        portnum2Proto[portnum] = name;
        proto2Portnum[name] = portnum;
    }
};

let sharedKeys = {};

function log0(fmt, ...args)
{
    DEBUG0("meshtastic_API: " + fmt, ...args);
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

function decodePacketObject(msg)
{
    if (!msg) {
        return null;
    }
    msg.hop_limit = 1;
    msg.transport = "meshtastic";
    msg.backend = "tcp-port-api";
    msg.originating_callsign = callsign;

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
    enabled = true;

    callsign = config.callsign;
    router = config.router;
    gatekeeper = config._gatekeeper;
    tcpHost = cfg.host;
    tcpPort = cfg.port ?? DEFAULT_PORT;

    s = openTcp();
    timers.setInterval("meshtastic_API.reconnect", RECONNECT_INTERVAL);
    loadSharedKeys();
    timers.setInterval("meshtastic_API.save", SAVE_INTERVAL);
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
    for (let i = 0; i < length(frames); i++) {
        const msg = decodeFromRadio(frames[i]);
        if (msg) {
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
        return s.recv(2048);
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
                    log0("send error: %s\n", socket.error());
                }
                else {
                    log0("send ok id=%s\n", msg.id);
                }
            }
        }
    }
    else {
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
    }
};

export function process(msg)
{
};
