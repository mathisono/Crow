// =====================================================================
// meshcore_tcp_api.uc
// =====================================================================
//
// Crow MeshCore TCP Companion API backend — text-message bridge only.
//
// Speaks the MeshCore Companion Protocol over TCP (default 127.0.0.1:4403):
//
//     Radio -> client: [ '>' ][ length LSB ][ length MSB ][ code + payload ]
//     Client -> radio: [ '<' ][ length LSB ][ length MSB ][ code + payload ]
//
// This backend is intentionally scoped to Crow's app goals:
//
//   * monitor messages from the connected MeshCore node for the public channel
//     and user-added/mapped channels;
//   * send text messages out through mapped MeshCore channel slots;
//   * receive direct messages delivered to the connected MeshCore node and create
//     a direct-message thread for the sender;
//   * send direct replies when Crow has learned the sender's MeshCore public-key
//     prefix from an inbound direct frame;
//   * protect AREDN nodes by using bounded frame parsing, one-at-a-time queued
//     message draining, paced channel discovery, and rate-limited non-message logs.
//
// =====================================================================

import * as socket from "socket";
import * as timers from "timers";
import * as channel from "channel";
import * as nodedb from "nodedb";
import * as fs from "fs";

// ---------------------------------------------------------------------
// Wire protocol constants
// ---------------------------------------------------------------------

const FRAME_FROM_RADIO         = 0x3E;   // '>'
const FRAME_TO_RADIO           = 0x3C;   // '<'
const HEADER_BYTES             = 3;      // marker(1) + length LE(2)

const SMART_MAX_PAYLOAD        = 512;
const RESYNC_BUFFER_CAP        = 4096;
const MAX_TEXT_MESSAGE_LENGTH  = 200;

// Commands host -> radio.
const CMD_APP_START            = 0x01;
const CMD_SEND_DIRECT_MESSAGE  = 0x02;
const CMD_SEND_CHANNEL_MESSAGE = 0x03;
const CMD_SYNC_NEXT_MESSAGE    = 0x0A;
const CMD_GET_CHANNEL          = 0x1F;

// Message responses radio -> host.
const RESP_MESSAGE_SENT        = 0x06;
const RESP_DIRECT_MSG_RECV     = 0x07;
const RESP_CHANNEL_MSG_RECV    = 0x08;
const RESP_NO_MORE_MESSAGES    = 0x0A;
const RESP_DIRECT_MSG_RECV_V3  = 0x10;
const RESP_CHANNEL_MSG_RECV_V3 = 0x11;
const RESP_CHANNEL_INFO        = 0x12;
const RESP_CHANNEL_DATA_RECV   = 0x1B;

// Device/config responses.
const RESP_SELF_INFO           = 0x05;
const RESP_LOG_DATA            = 0x88;
const RESP_TRACE_DATA          = 0x89;
const RESP_TELEMETRY_RESPONSE  = 0x8B;
const RESP_BINARY_RESPONSE     = 0x8C;
const RESP_CONTROL_DATA        = 0x8E;

// Push notifications.
const PUSH_CODE_SEND_CONFIRMED = 0x82;
const PUSH_CODE_MSG_WAITING    = 0x83;
const PUSH_CODE_RAW_DATA       = 0x84;
const PUSH_CODE_NEW_ADVERT     = 0x8A;
const PUSH_CODE_CONTACTS_FULL  = 0x90;

// Encrypted / non-compliant command IDs that are always early-dropped when
// Strict Gatekeeper is enabled. With strict mode off, they are still ignored by
// the non-message path rather than routed to Crow.
const CMD_ENCRYPTED_DM         = 0x90;
const CMD_ENCRYPTED_BIN        = 0x91;

const PART97_BLOCKED_COMMANDS = {
    [CMD_ENCRYPTED_DM]:  true,
    [CMD_ENCRYPTED_BIN]: true
};

const DEFAULT_HOST             = "127.0.0.1";
const DEFAULT_PORT             = 4403;
const RECONNECT_INTERVAL       = 5;
const SOCKET_READ_CHUNK        = 2048;
const DEFAULT_MAX_PENDING_RX   = 4;
const HARD_MAX_PENDING_RX      = 32;
const DEFAULT_CHANNEL_REFRESH  = 600;
const MAX_CHANNEL_INDEX        = 15;
const DEFAULT_DISCOVERY_WINDOW = 1;
const CHANNEL_REQUEST_TIMEOUT  = 5;
const UNKNOWN_LOG_INTERVAL     = 64;

const TEXT_TYPE_PLAIN          = 0x00;
const TEXT_TYPE_CLI_DATA       = 0x01;
const TEXT_TYPE_SIGNED         = 0x02;

function isDirectFrame(cmd)
{
    return cmd === RESP_DIRECT_MSG_RECV || cmd === RESP_DIRECT_MSG_RECV_V3;
}

function isGroupFrame(cmd)
{
    return cmd === RESP_CHANNEL_MSG_RECV || cmd === RESP_CHANNEL_MSG_RECV_V3;
}

// ---------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------

let cfg              = null;
let rootConfig       = null;
export let enabled   = false;
export let channelNamekey = null;
let deviceName       = null;
let channelCreated   = false;
let callsign         = null;
let router           = null;
let tcpHost          = null;
let tcpPort          = DEFAULT_PORT;
let nextReconnectTime = 0;
let strictHook       = null;
let channelDiscovery = false;
let channelRefreshSeconds = DEFAULT_CHANNEL_REFRESH;
let channelDiscoveryWindow = DEFAULT_DISCOVERY_WINDOW;

let s                = null;
let tcpbuf           = "";
let pendingSkip      = 0;
let pendingRx        = [];
let responses        = [];
let msgSeq           = 0;
let syncingMessages  = false;
let syncRequestInFlight = false;
let syncPausedBackpressure = false;
let discoveredChannels = {};
let unknownFrameCounts = {};
let meshcoreSelfPublicKey = null;
let meshcoreSelfPublicKeyPrefix = null;

let channelScanActive = false;
let channelScanNext = 0;
let channelScanInFlight = false;
let channelScanCurrent = null;
let lastChannelRequestTime = 0;

let stats            = {
    connects: 0,
    disconnects: 0,
    handshakes_sent: 0,
    bytes_rx: 0,
    frames_in: 0,
    frames_decoded: 0,
    self_info: 0,
    message_waiting: 0,
    no_more_messages: 0,
    sync_requests: 0,
    sync_backpressure: 0,
    responses_cached: 0,
    commands_sent: 0,
    sends_ok: 0,
    sends_failed: 0,
    direct_sends_ok: 0,
    direct_sends_failed: 0,
    channel_sends_ok: 0,
    channel_sends_failed: 0,
    channel_scans: 0,
    channel_discovery_requests: 0,
    channel_info_responses: 0,
    channel_discovery_timeouts: 0,
    channels_discovered: 0,
    channels_updated: 0,
    log_data_frames: 0,
    trace_data_frames: 0,
    telemetry_response_frames: 0,
    binary_response_frames: 0,
    control_data_frames: 0,
    message_sent_frames: 0,
    ack_frames: 0,
    unknown_frames: 0,
    unknown_frames_suppressed: 0,
    early_drop_oversize: 0,
    early_drop_encrypted: 0,
    early_drop_malformed_text: 0,
    resync_skips: 0
};
let lastRxTime       = null;
let lastCmd          = null;

// ---------------------------------------------------------------------
// Logging and operator notification
// ---------------------------------------------------------------------

function log0(fmt, ...args)
{
    DEBUG0("meshcore_tcp_api: " + fmt, ...args);
}

function log1(fmt, ...args)
{
    DEBUG1("meshcore_tcp_api: " + fmt, ...args);
}

function log2(fmt, ...args)
{
    DEBUG2("meshcore_tcp_api: " + fmt, ...args);
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
        `<b>MeshCore TCP API</b> ${verb} channel`,
        `Index ${ch.index}: ${ch.name}`,
        `Runtime only; not saved to Crow config.`
    ], `meshcore-tcp-channel-${ch.index}`);
}

function shouldLogFrame(code)
{
    const key = sprintf("0x%02x", code);
    const n = (unknownFrameCounts[key] ?? 0) + 1;
    unknownFrameCounts[key] = n;
    if (n <= 4) {
        return true;
    }
    if ((n % UNKNOWN_LOG_INTERVAL) === 0) {
        return true;
    }
    stats.unknown_frames_suppressed++;
    return false;
}

function countNonMessageFrame(cmd)
{
    switch (cmd) {
        case RESP_LOG_DATA:
            stats.log_data_frames++;
            return true;
        case RESP_TRACE_DATA:
            stats.trace_data_frames++;
            return true;
        case RESP_TELEMETRY_RESPONSE:
            stats.telemetry_response_frames++;
            return true;
        case RESP_BINARY_RESPONSE:
            stats.binary_response_frames++;
            return true;
        case RESP_CONTROL_DATA:
            stats.control_data_frames++;
            return true;
        case RESP_MESSAGE_SENT:
            stats.message_sent_frames++;
            return true;
        case PUSH_CODE_SEND_CONFIRMED:
            stats.ack_frames++;
            return true;
        case PUSH_CODE_RAW_DATA:
        case PUSH_CODE_NEW_ADVERT:
        case PUSH_CODE_CONTACTS_FULL:
            return true;
    }
    return false;
}

// ---------------------------------------------------------------------
// Channel helpers
// ---------------------------------------------------------------------

function localHostname()
{
    try {
        const h = fs.readfile("/proc/sys/kernel/hostname");
        if (h) return replace(h, "\n", "");
    } catch (e) {}
    return "";
}

function publicChannelLabel()
{
    const hostname = localHostname();
    const dev = deviceName ?? cfg?.device_name ?? "MeshCore";
    const chanName = cfg?.channel_name ?? "Public";
    return hostname
        ? `${hostname} ~${dev}~${chanName}`
        : `${dev}~${chanName}`;
}

function mapMeshcoreSlot(slot, chan)
{
    if (slot === null || slot === undefined || !chan) {
        return false;
    }
    return channel.setMeshcoreSlotChannel(slot, chan);
}

function ensureConfiguredPublicChannel(config)
{
    channelNamekey = channel.meshcorePublicChannelNamekey();
    if (!config.channels) config.channels = [];

    const label = publicChannelLabel();
    for (let i = 0; i < length(config.channels); i++) {
        if (config.channels[i].namekey === channelNamekey) {
            config.channels[i].label = label;
            log1("channel check: %s already configured\n", channelNamekey);
            return false;
        }
    }

    push(config.channels, { namekey: channelNamekey, label: label });
    log0("channel registered: %s (label: %s)\n", channelNamekey, label);
    return true;
}

function ensureRuntimePublicChannel()
{
    channelNamekey = channel.meshcorePublicChannelNamekey();

    const localChannels = channel.getAllLocalChannels();
    const label = publicChannelLabel();
    for (let i = 0; i < length(localChannels); i++) {
        if (localChannels[i].namekey === channelNamekey) {
            if (localChannels[i].label !== label) {
                localChannels[i].label = label;
                rootConfig.update?.("channels");
                log0("channel label updated: %s (label: %s)\n", channelNamekey, label);
            }
            mapMeshcoreSlot(0, localChannels[i]);
            channelCreated = true;
            return false;
        }
    }

    const chan = { namekey: channelNamekey, label: label };
    push(localChannels, chan);
    channel.updateLocalChannels(localChannels);
    rootConfig.update?.("channels");
    mapMeshcoreSlot(0, channel.getLocalChannelByNameKey(channelNamekey) ?? channel.addMessageNameKey(channelNamekey));
    channelCreated = true;
    log0("auto-created channel: %s (label: %s)\n", channelNamekey, label);
    return true;
}

function mapDiscoveredChannelIfLocal(ch)
{
    if (!ch || ch.index === null || !ch.namekey) {
        return false;
    }
    let chan = channel.getLocalChannelByNameKey(ch.namekey);
    if (!chan && ch.index === 0) {
        chan = channel.getLocalChannelByNameKey(channelNamekey) ?? channel.addMessageNameKey(channelNamekey);
    }
    if (chan) {
        mapMeshcoreSlot(ch.index, chan);
        return true;
    }
    return false;
}

function meshcoreChannelIndexForNamekey(namekey)
{
    if (!namekey || channel.isMeshcorePreset(namekey)) {
        return 0;
    }

    for (let idx in discoveredChannels) {
        if (discoveredChannels[idx]?.namekey === namekey) {
            return int(idx);
        }
    }

    const slots = cfg?.channel_slots ?? cfg?.channel_map;
    if (slots) {
        if (slots[namekey] !== null && slots[namekey] !== undefined) {
            return int(slots[namekey]);
        }
        const cname = split(namekey, " ")[0];
        if (slots[cname] !== null && slots[cname] !== undefined) {
            return int(slots[cname]);
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// Tiny binary helpers
// ---------------------------------------------------------------------

function le16(buf, off)
{
    return (ord(buf, off) & 0xFF) | ((ord(buf, off + 1) << 8) & 0xFF00);
}

function u32le(buf, off)
{
    return (ord(buf, off)
        | (ord(buf, off + 1) << 8)
        | (ord(buf, off + 2) << 16)
        | (ord(buf, off + 3) << 24)) & 0xFFFFFFFF;
}

function pack_le16(n)
{
    return chr(n & 0xFF) + chr((n >> 8) & 0xFF);
}

function pack_le32(n)
{
    return chr(n & 0xFF) + chr((n >> 8) & 0xFF) + chr((n >> 16) & 0xFF) + chr((n >> 24) & 0xFF);
}

function cstr(s)
{
    if (!s) return "";
    let n = length(s);
    while (n > 0 && ord(s, n - 1) === 0) n--;
    return substr(s, 0, n);
}

function textClean(s)
{
    return cstr(s ?? "");
}

function isMostlyPrintable(s)
{
    if (!s || length(s) === 0) return false;
    let printable = 0;
    for (let i = 0; i < length(s); i++) {
        const b = ord(s, i);
        if (b === 9 || b === 10 || b === 13 || (b >= 0x20 && b <= 0x7e) || b >= 0x80) {
            printable++;
        }
    }
    return printable >= length(s) * 0.75;
}

function idFromPrefix(prefix)
{
    if (!prefix || length(prefix) < 4) return 0;
    return u32le(prefix, 0);
}

function maxPendingRx()
{
    let n = cfg?.max_pending_rx ?? DEFAULT_MAX_PENDING_RX;
    if (n < 1) n = 1;
    if (n > HARD_MAX_PENDING_RX) n = HARD_MAX_PENDING_RX;
    return n;
}

function pendingFull()
{
    return length(pendingRx) >= maxPendingRx();
}

function directTargetId(msg)
{
    if (msg?.namekey && channel.isDirect(msg.namekey)) {
        const parts = split(msg.namekey, " ");
        if (length(parts) >= 2) {
            return int(parts[1]);
        }
    }
    return msg?.to;
}

function publicKeyPrefixFromNode(id)
{
    if (id === null || id === undefined) {
        return null;
    }
    const info = nodedb.getNode(id, false)?.nodeinfo;
    if (!info) {
        return null;
    }

    let key = info.mc_public_key ?? info.mc_public_key_prefix ?? info.public_key;
    if (key && length(key) >= 6) {
        return substr(key, 0, 6);
    }

    const b64 = info.mc_public_key_prefix_b64 ?? info.mc_public_key_b64 ?? info.public_key_b64;
    if (b64) {
        try {
            key = b64dec(b64);
            if (key && length(key) >= 6) {
                return substr(key, 0, 6);
            }
        }
        catch (_) {
        }
    }
    return null;
}

function rememberDirectPrefix(id, prefix)
{
    if (!id || !prefix || length(prefix) < 6) {
        return;
    }

    nodedb.createNode(id);
    nodedb.updateNodeinfo(id, {
        platform: "meshcore",
        mc_public_key_prefix: substr(prefix, 0, 6),
        mc_public_key_prefix_b64: b64enc(substr(prefix, 0, 6))
    });
}

// ---------------------------------------------------------------------
// Socket lifecycle
// ---------------------------------------------------------------------

function resetState()
{
    tcpbuf = "";
    pendingSkip = 0;
    syncingMessages = false;
    syncRequestInFlight = false;
    syncPausedBackpressure = false;
    channelScanActive = false;
    channelScanInFlight = false;
    channelScanCurrent = null;
}

function disableNagle(sock)
{
    if (!sock) return false;
    try {
        const nodelay = socket.TCP_NODELAY ?? 1;
        const ipproto = socket.IPPROTO_TCP ?? 6;
        if (type(sock.setsockopt) === "function") {
            sock.setsockopt(ipproto, nodelay, 1);
            log1("tcp nodelay enabled\n");
            return true;
        }
        if (type(sock.setoption) === "function") {
            sock.setoption(ipproto, nodelay, 1);
            log1("tcp nodelay enabled\n");
            return true;
        }
    }
    catch (e) {
        log1("tcp nodelay unavailable: %s\n", e);
    }
    return false;
}

function closeSocket(reason)
{
    if (s) {
        log0("disconnect %s (bytes_rx=%d frames_in=%d decoded=%d last_cmd=%s)\n",
            reason ?? "",
            stats.bytes_rx,
            stats.frames_in,
            stats.frames_decoded,
            lastCmd != null ? sprintf("0x%02x", lastCmd) : "none");
        stats.disconnects++;
        try { s.close(); } catch (_) {}
    }
    s = null;
    nextReconnectTime = time() + RECONNECT_INTERVAL;
    resetState();
}

function openTcp()
{
    if (!tcpHost) {
        log0("tcp host not configured; backend disabled\n");
        return null;
    }
    try {
        const ns = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
        disableNagle(ns);
        ns.connect({ address: tcpHost, port: tcpPort });
        log0("connected tcp companion %s:%d\n", tcpHost, tcpPort);
        stats.connects++;
        return ns;
    }
    catch (_) {
        log0("tcp connect failed %s:%d: %s\n", tcpHost, tcpPort, socket.error());
        nextReconnectTime = time() + RECONNECT_INTERVAL;
        return null;
    }
}

// ---------------------------------------------------------------------
// MeshCore boot handshake, queue polling, channel discovery, and sending.
// ---------------------------------------------------------------------

function buildRadioFrame(cmd, payload)
{
    payload = payload ?? "";
    const framePayload = chr(cmd & 0xFF) + payload;
    return chr(FRAME_FROM_RADIO) + pack_le16(length(framePayload)) + framePayload;
}

function buildCommand(cmd, payload)
{
    payload = payload ?? "";
    const framePayload = chr(cmd & 0xFF) + payload;
    return chr(FRAME_TO_RADIO) + pack_le16(length(framePayload)) + framePayload;
}

export function sendCommand(cmd, payload)
{
    if (!s) return false;
    try {
        const frame = buildCommand(cmd, payload ?? "");
        const sent = s.send(frame);
        stats.commands_sent++;
        log1("send command=0x%02x frame_bytes=%d sent=%s\n", cmd, length(frame), sent);
        return true;
    }
    catch (_) {
        closeSocket("command send failed: " + socket.error());
        return false;
    }
};

function appStartPayload()
{
    return chr(0) + chr(0) + chr(0) + chr(0) + chr(0) + chr(0) + chr(0) + "Crow";
}

function sendBootHandshake()
{
    if (!s) return;
    try {
        const payload = appStartPayload();
        const frame = buildCommand(CMD_APP_START, payload);
        const sent = s.send(frame);
        stats.handshakes_sent++;
        log0("handshake sent (CMD_APP_START) frame_bytes=%d sent=%s\n", length(frame), sent);
        log1("  expecting RESP_SELF_INFO(0x05), PUSH_MSG_WAITING(0x83), then bounded SYNC_NEXT_MESSAGE drain\n");
    }
    catch (_) {
        closeSocket("handshake send failed: " + socket.error());
    }
}

function pauseSyncForBackpressure(reason)
{
    if (!syncPausedBackpressure) {
        log1("sync backpressure: pending_rx=%d max=%d reason=%s\n",
            length(pendingRx), maxPendingRx(), reason ?? "unknown");
    }
    syncPausedBackpressure = true;
    stats.sync_backpressure++;
}

function sendSyncNextMessage(reason)
{
    if (!s) return false;
    if (syncRequestInFlight) return false;
    if (pendingFull()) {
        pauseSyncForBackpressure(reason);
        syncingMessages = true;
        return false;
    }

    syncingMessages = true;
    syncRequestInFlight = true;
    syncPausedBackpressure = false;
    stats.sync_requests++;
    log1("sync next message reason=%s\n", reason ?? "unknown");

    const ok = sendCommand(CMD_SYNC_NEXT_MESSAGE, "");
    if (!ok) {
        syncRequestInFlight = false;
    }
    return ok;
}

function maybeRequestNext(reason)
{
    if (!syncingMessages || syncRequestInFlight || !s) return false;
    return sendSyncNextMessage(reason);
}

function requestChannelInfo(index, reason)
{
    if (!channelDiscovery || !s) {
        return false;
    }
    stats.channel_discovery_requests++;
    channelScanInFlight = true;
    channelScanCurrent = index;
    lastChannelRequestTime = time();
    log1("channel discovery request index=%d reason=%s\n", index, reason ?? "unknown");
    return sendCommand(CMD_GET_CHANNEL, chr(index & 0xff));
}

function startChannelScan(reason)
{
    if (!channelDiscovery || !s || channelScanActive) {
        return;
    }
    channelScanActive = true;
    channelScanNext = 0;
    channelScanInFlight = false;
    channelScanCurrent = null;
    stats.channel_scans++;
    log1("channel discovery scan start reason=%s\n", reason ?? "unknown");
    continueChannelScan(reason);
}

function continueChannelScan(reason)
{
    if (!channelDiscovery || !s || !channelScanActive || channelScanInFlight) {
        return;
    }
    if (channelScanNext > MAX_CHANNEL_INDEX) {
        channelScanActive = false;
        channelScanCurrent = null;
        log1("channel discovery scan complete\n");
        return;
    }
    const idx = channelScanNext++;
    requestChannelInfo(idx, reason);
}

function checkChannelScanTimeout()
{
    if (!channelScanActive || !channelScanInFlight) {
        return;
    }
    if (time() - lastChannelRequestTime >= CHANNEL_REQUEST_TIMEOUT) {
        stats.channel_discovery_timeouts++;
        log1("channel discovery timeout index=%s\n", channelScanCurrent);
        channelScanInFlight = false;
        channelScanCurrent = null;
        continueChannelScan("timeout");
    }
}

function buildSendChannelPayload(index, text)
{
    text = substr(text ?? "", 0, MAX_TEXT_MESSAGE_LENGTH);
    return chr(TEXT_TYPE_PLAIN) + chr(index & 0xff) + pack_le32(time()) + text;
}

function buildSendDirectPayload(prefix, text, attempt)
{
    text = substr(text ?? "", 0, MAX_TEXT_MESSAGE_LENGTH);
    attempt = attempt ?? 0;
    return chr(TEXT_TYPE_PLAIN) + chr(attempt & 0xff) + pack_le32(time()) + substr(prefix, 0, 6) + text;
}

// ---------------------------------------------------------------------
// Response parsers
// ---------------------------------------------------------------------

function parseSelfInfo(framePayload)
{
    if (!framePayload || length(framePayload) < 2 || ord(framePayload, 0) !== RESP_SELF_INFO) {
        return null;
    }

    // MeshCoreOne documents the self-info payload after the code byte as:
    // offset 0..2 adv/tx/max_tx, offset 3..34 public key, offset 57+ name.
    // Since framePayload includes the response code at byte 0, the public key
    // starts at 4 and the name starts at 58.
    if (length(framePayload) >= 36) {
        meshcoreSelfPublicKey = substr(framePayload, 4, 32);
        meshcoreSelfPublicKeyPrefix = substr(meshcoreSelfPublicKey, 0, 6);
    }

    let name = null;
    if (length(framePayload) > 58) {
        name = textClean(substr(framePayload, 58));
        if (!isMostlyPrintable(name)) {
            name = null;
        }
    }

    if (!name) {
        let nameStart = 36;
        const payloadLen = length(framePayload);
        while (nameStart < payloadLen) {
            const byte = ord(framePayload, nameStart);
            if ((byte >= 0x20 && byte <= 0x7E) || byte >= 0x80) break;
            nameStart++;
        }
        if (nameStart < payloadLen) {
            name = textClean(substr(framePayload, nameStart));
        }
    }

    if (name && length(name) > 0) {
        log0("parseSelfInfo: device name = %s\n", name);
        return name;
    }

    log1("parseSelfInfo: no printable name found\n");
    return null;
}

function directMsg(fromId, prefix, text, textType, timestamp, snr, pathLen, strong)
{
    if (!text || length(text) === 0) {
        return null;
    }

    if (prefix && length(prefix) >= 6) {
        rememberDirectPrefix(fromId, prefix);
    }
    else {
        nodedb.createNode(fromId);
    }

    msgSeq = (msgSeq + 1) & 0xFFFFFFFF;
    const namekey = nodedb.namekey(fromId);
    return {
        id:                   msgSeq,
        from:                 fromId,
        to:                   0,
        rx_time:              timestamp ?? time(),
        hop_limit:            1,
        transport:            "meshcore",
        backend:              "tcp_api",
        originating_callsign: callsign,
        namekey:              namekey,
        data: {
            text_message: text
        },
        metadata: {
            is_group_message: false,
            local_direct: true,
            meshcore_sender_prefix: prefix ? b64enc(prefix) : null,
            text_type: textType,
            path_length: pathLen,
            rx_snr: snr,
            identity_strength: strong ? "strong" : "weak"
        }
    };
}

function channelMsg(index, text, textType, timestamp, snr, pathLen)
{
    if (!text || length(text) === 0) {
        return null;
    }

    msgSeq = (msgSeq + 1) & 0xFFFFFFFF;
    const mapped = channel.getChannelByMeshcoreSlot(index);
    return {
        id:                   msgSeq,
        from:                 0,
        group_slot:           index,
        channel_index:        index,
        rx_time:              timestamp ?? time(),
        hop_limit:            1,
        transport:            "meshcore",
        backend:              "tcp_api",
        originating_callsign: callsign,
        namekey:              mapped?.namekey ?? (index === 0 ? channelNamekey : null),
        data: {
            text_message: text
        },
        metadata: {
            is_group_message: true,
            group_slot: index,
            channel_index: index,
            text_type: textType,
            path_length: pathLen,
            rx_snr: snr,
            identity_strength: "weak",
            symmetric_key: true,
            requires_slot_lookup: index !== 0
        }
    };
}

function parseDirectModern(payload, version)
{
    let off = 0;
    let snr = null;
    if (version === 3) {
        if (length(payload) < 15) return null;
        snr = (ord(payload, 0) > 127 ? ord(payload, 0) - 256 : ord(payload, 0)) / 4.0;
        off = 3;
    }
    else {
        if (length(payload) < 12) return null;
        off = 0;
    }

    const prefix = substr(payload, off, 6); off += 6;
    const pathLen = ord(payload, off); off++;
    const textType = ord(payload, off); off++;
    const timestamp = u32le(payload, off); off += 4;
    if (textType === TEXT_TYPE_SIGNED && length(payload) >= off + 4) {
        off += 4;
    }
    const text = textClean(substr(payload, off));
    if (!isMostlyPrintable(text)) return null;
    return directMsg(idFromPrefix(prefix), prefix, text, textType, timestamp, snr, pathLen, true);
}

function parseDirectLegacy(payload)
{
    if (length(payload) < 9) return null;
    const fromId = u32le(payload, 0);
    const toId = u32le(payload, 4);
    const tlen = ord(payload, 8);
    if (9 + tlen > length(payload)) return null;
    const text = textClean(substr(payload, 9, tlen));
    if (!isMostlyPrintable(text)) return null;
    const msg = directMsg(fromId, null, text, TEXT_TYPE_PLAIN, time(), null, null, true);
    if (msg) msg.to = toId;
    return msg;
}

function parseChannelModern(payload, version)
{
    let off = 0;
    let snr = null;
    if (version === 3) {
        if (length(payload) < 10) return null;
        snr = (ord(payload, 0) > 127 ? ord(payload, 0) - 256 : ord(payload, 0)) / 4.0;
        off = 3;
    }
    else {
        if (length(payload) < 7) return null;
        off = 0;
    }

    const index = ord(payload, off); off++;
    const pathLen = ord(payload, off); off++;
    const textType = ord(payload, off); off++;
    const timestamp = u32le(payload, off); off += 4;
    const text = textClean(substr(payload, off));
    if (!isMostlyPrintable(text)) return null;
    return channelMsg(index, text, textType, timestamp, snr, pathLen);
}

function parseChannelLegacy(payload)
{
    if (length(payload) < 5) return null;
    const fromId = u32le(payload, 0);
    const index = ord(payload, 4);
    const text = textClean(substr(payload, 5));
    if (!isMostlyPrintable(text)) return null;
    const msg = channelMsg(index, text, TEXT_TYPE_PLAIN, time(), null, null);
    if (msg) msg.from = fromId;
    return msg;
}

function decodeTextFrame(cmd, payload)
{
    let msg = null;
    if (cmd === RESP_DIRECT_MSG_RECV_V3) {
        msg = parseDirectModern(payload, 3) ?? parseDirectLegacy(payload);
    }
    else if (cmd === RESP_DIRECT_MSG_RECV) {
        msg = parseDirectModern(payload, 1) ?? parseDirectLegacy(payload);
    }
    else if (cmd === RESP_CHANNEL_MSG_RECV_V3) {
        msg = parseChannelModern(payload, 3) ?? parseChannelLegacy(payload);
    }
    else if (cmd === RESP_CHANNEL_MSG_RECV) {
        msg = parseChannelModern(payload, 1) ?? parseChannelLegacy(payload);
    }

    if (msg) {
        log1("decoded MeshCore cmd=0x%02x text=%d bytes namekey=%s\n",
            cmd, length(msg.data.text_message), msg.namekey ?? "");
        return msg;
    }

    stats.early_drop_malformed_text++;
    log1("decode: malformed text frame cmd=0x%02x len=%d\n", cmd, length(payload));
    return null;
}

function decodeChannelInfo(framePayload)
{
    if (!framePayload || length(framePayload) < 50 || ord(framePayload, 0) !== RESP_CHANNEL_INFO) {
        return null;
    }
    const index = ord(framePayload, 1);
    const name = cstr(substr(framePayload, 2, 32));
    const secret = substr(framePayload, 34, 16);
    if (!name || length(name) === 0 || !secret || length(secret) === 0) {
        return null;
    }
    const secret_b64 = b64enc(secret);
    return {
        index: index,
        name: name,
        secret: secret,
        secret_b64: secret_b64,
        namekey: `${name} ${secret_b64}`
    };
}

function processChannelInfo(framePayload)
{
    stats.channel_info_responses++;
    channelScanInFlight = false;
    channelScanCurrent = null;

    const ch = decodeChannelInfo(framePayload);
    if (!ch) {
        continueChannelScan("bad-channel-info");
        return;
    }

    const key = `${ch.index}`;
    const old = discoveredChannels[key];
    if (!old) {
        discoveredChannels[key] = ch;
        stats.channels_discovered++;
        log1("channel discovered index=%d name=%s\n", ch.index, ch.name);
        notifyChannelDiscovered(ch, "discovered");
    }
    else if (old.name !== ch.name || old.secret_b64 !== ch.secret_b64) {
        discoveredChannels[key] = ch;
        stats.channels_updated++;
        log1("channel updated index=%d name=%s\n", ch.index, ch.name);
        notifyChannelDiscovered(ch, "updated");
    }

    mapDiscoveredChannelIfLocal(ch);
    continueChannelScan("channel-info");
}

// ---------------------------------------------------------------------
// Smart accumulator: frames -> typed actions/messages
// ---------------------------------------------------------------------

function advance(hdrBytes, payloadBytes)
{
    const total = hdrBytes + payloadBytes;
    if (length(tcpbuf) >= total) {
        tcpbuf = substr(tcpbuf, total);
        return;
    }
    pendingSkip = total - length(tcpbuf);
    tcpbuf = "";
}

function smartAccumulate(data)
{
    const frames = [];

    if (pendingSkip > 0 && length(data) > 0) {
        const drop = pendingSkip < length(data) ? pendingSkip : length(data);
        data = substr(data, drop);
        pendingSkip -= drop;
        if (pendingSkip > 0) return frames;
    }

    if (length(data) > 0) {
        tcpbuf += data;
    }

    const strictOn = strictHook ? strictHook() : false;

    for (;;) {
        const blen = length(tcpbuf);
        if (blen === 0) return frames;

        if (ord(tcpbuf, 0) !== FRAME_FROM_RADIO) {
            let start = -1;
            for (let i = 1; i < blen; i++) {
                if (ord(tcpbuf, i) === FRAME_FROM_RADIO) { start = i; break; }
            }
            if (start < 0) {
                if (blen > RESYNC_BUFFER_CAP) {
                    stats.resync_skips++;
                    log1("resync: dropped %d bytes of pre-magic garbage\n", blen);
                    tcpbuf = "";
                }
                return frames;
            }
            stats.resync_skips++;
            log1("resync: skipped %d bytes before magic\n", start);
            tcpbuf = substr(tcpbuf, start);
            continue;
        }

        if (blen < HEADER_BYTES) return frames;

        const plen = le16(tcpbuf, 1);
        if (plen > SMART_MAX_PAYLOAD) {
            stats.early_drop_oversize++;
            log1("early-drop oversize plen=%d > %d\n", plen, SMART_MAX_PAYLOAD);
            advance(HEADER_BYTES, plen);
            continue;
        }

        if (blen < HEADER_BYTES + plen) return frames;
        if (plen < 1) {
            stats.early_drop_malformed_text++;
            tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
            continue;
        }

        const framePayload = substr(tcpbuf, HEADER_BYTES, plen);
        const cmd = ord(framePayload, 0);
        const payload = substr(framePayload, 1);
        tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
        stats.frames_in++;
        lastCmd = cmd;

        if (cmd === PUSH_CODE_MSG_WAITING) {
            stats.message_waiting++;
            syncingMessages = true;
            maybeRequestNext("push 0x83");
            continue;
        }

        if (cmd === RESP_NO_MORE_MESSAGES) {
            stats.no_more_messages++;
            syncingMessages = false;
            syncRequestInFlight = false;
            syncPausedBackpressure = false;
            log1("sync queue empty (0x0a)\n");
            continue;
        }

        if (strictOn && PART97_BLOCKED_COMMANDS[cmd]) {
            stats.early_drop_encrypted++;
            syncRequestInFlight = false;
            log1("early-drop encrypted cmd=0x%02x plen=%d (Part 97)\n", cmd, plen);
            maybeRequestNext("drop encrypted");
            continue;
        }

        if (cmd === RESP_SELF_INFO) {
            stats.self_info++;
            syncRequestInFlight = false;
            const name = parseSelfInfo(framePayload);
            if (name) {
                deviceName = name;
                channelCreated = false;
            }
            startChannelScan("self-info");
            continue;
        }

        if (cmd === RESP_CHANNEL_INFO) {
            stats.responses_cached++;
            syncRequestInFlight = false;
            push(responses, { cmd: cmd, payload: framePayload });
            processChannelInfo(framePayload);
            continue;
        }

        if (isDirectFrame(cmd) || isGroupFrame(cmd)) {
            syncRequestInFlight = false;
            push(frames, { cmd: cmd, payload: payload });
            continue;
        }

        if (cmd === RESP_CHANNEL_DATA_RECV) {
            syncRequestInFlight = false;
            log2("drop channel datagram len=%d\n", length(payload));
            maybeRequestNext("drop channel data");
            continue;
        }

        if (countNonMessageFrame(cmd)) {
            if (cmd === RESP_LOG_DATA) {
                if (shouldLogFrame(cmd)) {
                    log2("log data frame len=%d count=%d\n", length(payload), unknownFrameCounts[sprintf("0x%02x", cmd)]);
                }
            }
            continue;
        }

        stats.unknown_frames++;
        syncRequestInFlight = false;
        if (shouldLogFrame(cmd)) {
            log1("drop non-message cmd=0x%02x plen=%d count=%d\n",
                cmd, plen, unknownFrameCounts[sprintf("0x%02x", cmd)]);
        }
        maybeRequestNext("drop unknown");
    }
}

function popPending(reason)
{
    if (length(pendingRx) === 0) return null;
    const msg = shift(pendingRx);
    maybeRequestNext(reason ?? "pending delivered");
    return msg;
}

// ---------------------------------------------------------------------
// Public lifecycle API
// ---------------------------------------------------------------------

export function setup(config)
{
    cfg = config.meshcore_tcp_api;
    rootConfig = config;
    if (!cfg || cfg.enabled === false) {
        return;
    }
    enabled = true;

    callsign = config.callsign;
    router   = config.router;
    tcpHost  = cfg.host ?? DEFAULT_HOST;
    tcpPort  = cfg.port ?? DEFAULT_PORT;
    channelDiscovery = !!cfg.channel_discovery;
    channelRefreshSeconds = cfg.channel_refresh_seconds ?? DEFAULT_CHANNEL_REFRESH;
    channelDiscoveryWindow = cfg.channel_discovery_window ?? DEFAULT_DISCOVERY_WINDOW;
    if (channelDiscoveryWindow < 1) channelDiscoveryWindow = 1;
    if (channelDiscoveryWindow > 4) channelDiscoveryWindow = 4;

    deviceName = cfg.device_name ?? null;
    channelCreated = ensureConfiguredPublicChannel(config);

    const gk = config._gatekeeper;
    strictHook = gk && type(gk.isEnabled) === "function"
        ? function () { return gk.isEnabled() === true; }
        : null;

    nextReconnectTime = 0;
    s = openTcp();
    if (s) sendBootHandshake();
    if (channelDiscovery) {
        timers.setInterval("meshcore_tcp_api.channel_refresh", channelRefreshSeconds);
    }
};

export function shutdown()
{
    closeSocket("shutdown");
};

export function handle()
{
    return s;
};

function readSocket()
{
    if (!s) return null;
    try {
        const data = s.recv(SOCKET_READ_CHUNK);
        if (!data || length(data) === 0) {
            closeSocket("peer closed");
            return null;
        }
        stats.bytes_rx += length(data);
        lastRxTime = time();
        return data;
    }
    catch (_) {
        closeSocket(socket.error());
        return null;
    }
}

export function recv()
{
    const queued = popPending("pending delivered");
    if (queued) return queued;

    if (!s) return null;

    const data = readSocket();
    if (!data) return null;

    const frames = smartAccumulate(data);
    for (let i = 0; i < length(frames); i++) {
        const f = frames[i];
        const msg = decodeTextFrame(f.cmd, f.payload);
        if (msg) {
            stats.frames_decoded++;
            push(pendingRx, msg);
        }
    }

    const msg = popPending("message delivered");
    if (msg) return msg;

    maybeRequestNext("resume drain");
    return null;
};

export function send(msg)
{
    if (!s) {
        stats.sends_failed++;
        log1("send: disconnected (msg.id=%s)\n", msg?.id);
        return false;
    }
    if (!msg?.data?.text_message) {
        stats.sends_failed++;
        log1("send: no text payload (msg.id=%s)\n", msg?.id);
        return false;
    }

    if (channel.isDirect(msg.namekey)) {
        const targetId = directTargetId(msg);
        const prefix = publicKeyPrefixFromNode(targetId);
        if (!prefix || length(prefix) < 6) {
            stats.sends_failed++;
            stats.direct_sends_failed++;
            log1("send direct: missing MeshCore public-key prefix target=%s msg.id=%s\n", targetId, msg?.id);
            return false;
        }

        const attempt = msg.metadata?.retry_attempt ?? msg.retry_attempt ?? 0;
        const payload = buildSendDirectPayload(prefix, msg.data.text_message, attempt);
        const ok = sendCommand(CMD_SEND_DIRECT_MESSAGE, payload);
        if (ok) {
            stats.sends_ok++;
            stats.direct_sends_ok++;
            log1("send direct ok target=%s msg.id=%s\n", targetId, msg?.id);
        }
        else {
            stats.sends_failed++;
            stats.direct_sends_failed++;
            log1("send direct failed target=%s msg.id=%s\n", targetId, msg?.id);
        }
        return ok;
    }

    const idx = msg.group_slot ?? msg.channel_index ?? meshcoreChannelIndexForNamekey(msg.namekey);
    if (idx === null || idx === undefined || idx < 0 || idx > MAX_CHANNEL_INDEX) {
        stats.sends_failed++;
        stats.channel_sends_failed++;
        log1("send channel: no MeshCore slot for namekey=%s msg.id=%s\n", msg.namekey ?? "", msg?.id);
        return false;
    }

    const payload = buildSendChannelPayload(idx, msg.data.text_message);
    const ok = sendCommand(CMD_SEND_CHANNEL_MESSAGE, payload);
    if (ok) {
        stats.sends_ok++;
        stats.channel_sends_ok++;
        log1("send channel ok slot=%d msg.id=%s\n", idx, msg?.id);
    }
    else {
        stats.sends_failed++;
        stats.channel_sends_failed++;
        log1("send channel failed slot=%d msg.id=%s\n", idx, msg?.id);
    }
    return ok;
};

export function tick()
{
    if (enabled && !channelCreated && channel) {
        try {
            ensureRuntimePublicChannel();
        }
        catch (err) {
            log0("auto channel check error: %s\n", err);
            stats.unknown_frames++;
        }
    }
    if (enabled && !s && time() >= nextReconnectTime) {
        nextReconnectTime = time() + RECONNECT_INTERVAL;
        s = openTcp();
        if (s) sendBootHandshake();
    }
    if (enabled && s && syncingMessages && !syncRequestInFlight && !pendingFull()) {
        maybeRequestNext(syncPausedBackpressure ? "resume after backpressure" : "tick resume");
    }
    if (enabled && s && channelDiscovery && timers.tick("meshcore_tcp_api.channel_refresh")) {
        startChannelScan("refresh");
    }
    checkChannelScanTimeout();
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
        handshakes_sent: stats.handshakes_sent,
        bytes_rx: stats.bytes_rx,
        frames_in: stats.frames_in,
        frames_decoded: stats.frames_decoded,
        self_info: stats.self_info,
        message_waiting: stats.message_waiting,
        commands_sent: stats.commands_sent,
        responses_cached: stats.responses_cached,
        sync_requests: stats.sync_requests,
        sync_backpressure: stats.sync_backpressure,
        no_more_messages: stats.no_more_messages,
        pending_rx: length(pendingRx),
        max_pending_rx: maxPendingRx(),
        sends_ok: stats.sends_ok,
        sends_failed: stats.sends_failed,
        direct_sends_ok: stats.direct_sends_ok,
        direct_sends_failed: stats.direct_sends_failed,
        channel_sends_ok: stats.channel_sends_ok,
        channel_sends_failed: stats.channel_sends_failed,
        last_rx_time: lastRxTime,
        last_cmd: lastCmd,
        syncing_messages: syncingMessages,
        sync_request_in_flight: syncRequestInFlight,
        sync_paused_backpressure: syncPausedBackpressure,
        channel_discovery: channelDiscovery,
        channel_scans: stats.channel_scans,
        channel_discovery_requests: stats.channel_discovery_requests,
        channel_info_responses: stats.channel_info_responses,
        channel_discovery_timeouts: stats.channel_discovery_timeouts,
        channels_discovered: stats.channels_discovered,
        channels_updated: stats.channels_updated,
        log_data_frames: stats.log_data_frames,
        trace_data_frames: stats.trace_data_frames,
        telemetry_response_frames: stats.telemetry_response_frames,
        binary_response_frames: stats.binary_response_frames,
        control_data_frames: stats.control_data_frames,
        message_sent_frames: stats.message_sent_frames,
        ack_frames: stats.ack_frames,
        unknown_frames: stats.unknown_frames,
        unknown_frames_suppressed: stats.unknown_frames_suppressed
    };
};

// ---------------------------------------------------------------------
// Test/introspection hooks
// ---------------------------------------------------------------------

export function _test_inject(data, gatekeeperShim)
{
    if (gatekeeperShim !== null && gatekeeperShim !== undefined) {
        strictHook = function () {
            return gatekeeperShim.isEnabled() === true;
        };
    }
    return smartAccumulate(data);
};

export function _test_decode(cmd, payload)
{
    return decodeTextFrame(cmd, payload);
};

export function _test_reset()
{
    resetState();
    pendingRx = [];
    responses = [];
    msgSeq = 0;
    discoveredChannels = {};
    unknownFrameCounts = {};
    meshcoreSelfPublicKey = null;
    meshcoreSelfPublicKeyPrefix = null;
    for (let k in stats) stats[k] = 0;
};

export function _test_stats()
{
    return stats;
};

export function _test_take_response(cmd)
{
    return takeResponse(cmd);
};

export function takeResponse(cmd)
{
    for (let i = 0; i < length(responses); i++) {
        if (responses[i].cmd === cmd) {
            const resp = responses[i];
            splice(responses, i, 1);
            return resp;
        }
    }
    return null;
};

export function _test_build_frame(cmd, payload)
{
    return buildRadioFrame(cmd, payload);
};

export function _test_build_command(cmd, payload)
{
    return buildCommand(cmd, payload);
};

export function _test_app_start_payload()
{
    return appStartPayload();
};

export function _test_build_direct_send(prefix, text, attempt)
{
    return buildCommand(CMD_SEND_DIRECT_MESSAGE, buildSendDirectPayload(prefix, text, attempt));
};
