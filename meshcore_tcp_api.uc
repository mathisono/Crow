// =====================================================================
// meshcore_tcp_api.uc
// =====================================================================
//
// Crow MeshCore TCP Companion API backend — text-message bridge only.
//
// Speaks the MeshCore Companion Protocol over TCP (default 127.0.0.1:4403),
// the same binary protocol used by MeshMonitor. This is NOT Meshtastic's
// port 4403 (which streams raw protobufs). MeshCore Companion frames:
//
//     Radio -> client: [ '>' ][ length LSB ][ length MSB ][ code + payload ]
//     Client -> radio: [ '<' ][ length LSB ][ length MSB ][ code + payload ]
//
// Scope: this backend ONLY surfaces cleartext text messages (TXT_MSG +
// GRP_TXT) into the Crow router. Every other frame — handshake responses,
// adverts, encrypted blobs, unknown commands — is dropped at the buffer
// layer without payload allocation. This minimises RAM exposure on
// OpenWrt nodes and keeps the regulatory surface tight (FCC Part 97).
//
// Design pillars:
//
//   1. Non-blocking ucode socket integrated with Crow's timer-driven
//      recv/send loop (same shape as meshtastic_API.uc).
//   2. "Smart Accumulator" — Strict Gatekeeper / Part 97 rules are
//      enforced AT the buffer level. Oversized frames, encrypted payload
//      types, and any command outside { TXT_MSG, GRP_TXT } are skipped
//      from the wire BEFORE allocating a payload buffer.
//   3. MeshCore Companion boot handshake — CMD_APP_START with the required
//      seven reserved bytes plus the application name "Crow".
//   4. Push-notify + pull queue model — 0x83 means message waiting; Crow
//      sends CMD_SYNC_NEXT_MESSAGE to pull queued messages deliberately.
//   5. Backpressure — Crow never treats MeshCore as a firehose. It keeps a
//      bounded local pending queue and asks for the next radio message only
//      when local pending work is below the configured cap.
//   6. Reconnect backoff with stable state-machine reset.
//   7. Decoded messages are queued raw; router.uc runs the canonical
//      gatekeeper.filterInboundBridge() pass (no double-filtering).
//
// This backend is EXPERIMENTAL. It is not wired into router.uc by default.
// Enable via config:
//
//     "meshcore_tcp_api": {
//         "enabled": true,
//         "host": "127.0.0.1",
//         "port": 4403,
//         "max_pending_rx": 4,
//         "channel_discovery": true
//     }
//
// =====================================================================

import * as socket from "socket";
import * as timers from "timers";
import * as channel from "channel";
import * as fs from "fs";

// ---------------------------------------------------------------------
// Wire protocol constants
// ---------------------------------------------------------------------

const FRAME_FROM_RADIO         = 0x3E;   // '>'
const FRAME_TO_RADIO           = 0x3C;   // '<'
const HEADER_BYTES             = 3;      // marker(1) + length LE(2)

const SMART_MAX_PAYLOAD        = 256;
const RESYNC_BUFFER_CAP        = 4096;

const CMD_DIRECT_MSG_RECV      = 0x07;
const CMD_CHANNEL_MSG_RECV     = 0x08;
const CMD_DIRECT_MSG_RECV_V3   = 0x10;
const CMD_CHANNEL_MSG_RECV_V3  = 0x11;

const CMD_APP_START            = 0x01;
const CMD_SYNC_NEXT_MESSAGE    = 0x0A;
const CMD_GET_CHANNEL          = 0x1F;

const RESP_SELF_INFO           = 0x05;
const SELF_INFO_PUBKEY_SIZE    = 32;
const SELF_INFO_PUBKEY_OFFSET  = 1;

const PUSH_CODE_SEND_CONFIRMED = 0x82;
const PUSH_CODE_MSG_WAITING    = 0x83;
const RESP_CHANNEL_INFO        = 0x12;
const RESP_NO_MORE_MESSAGES    = 0x0A;

const CMD_ENCRYPTED_DM         = 0x90;
const CMD_ENCRYPTED_BIN        = 0x91;

const PART97_BLOCKED_COMMANDS = {
    [CMD_ENCRYPTED_DM]:  true,
    [CMD_ENCRYPTED_BIN]: true
};

function isDirectFrame(cmd)
{
    return cmd === CMD_DIRECT_MSG_RECV || cmd === CMD_DIRECT_MSG_RECV_V3;
}

function isGroupFrame(cmd)
{
    return cmd === CMD_CHANNEL_MSG_RECV || cmd === CMD_CHANNEL_MSG_RECV_V3;
}

const DEFAULT_HOST             = "127.0.0.1";
const DEFAULT_PORT             = 4403;
const RECONNECT_INTERVAL       = 5;
const SOCKET_READ_CHUNK        = 2048;
const DEFAULT_MAX_PENDING_RX   = 4;
const HARD_MAX_PENDING_RX      = 32;
const DEFAULT_CHANNEL_REFRESH  = 600;
const MAX_CHANNEL_INDEX        = 7;

const TEXT_ENVELOPE_BYTES      = 9;

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
    channel_discovery_requests: 0,
    channel_info_responses: 0,
    channels_discovered: 0,
    channels_updated: 0,
    early_drop_oversize: 0,
    early_drop_encrypted: 0,
    early_drop_unknown_cmd: 0,
    early_drop_malformed_text: 0,
    resync_skips: 0
};
let lastRxTime       = null;
let lastCmd          = null;

// ---------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------

function log0(fmt, ...args)
{
    DEBUG0("meshcore_tcp_api: " + fmt, ...args);
}

function log1(fmt, ...args)
{
    DEBUG1("meshcore_tcp_api: " + fmt, ...args);
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
            channelCreated = true;
            return false;
        }
    }

    push(localChannels, { namekey: channelNamekey, label: label });
    channel.updateLocalChannels(localChannels);
    rootConfig.update?.("channels");
    channelCreated = true;
    log0("auto-created channel: %s (label: %s)\n", channelNamekey, label);
    return true;
}

// ---------------------------------------------------------------------
// Tiny binary helpers
// ---------------------------------------------------------------------

function le16(buf, off)
{
    return (ord(buf, off) & 0xFF) | ((ord(buf, off + 1) << 8) & 0xFF00);
}

function pack_le16(n)
{
    return chr(n & 0xFF) + chr((n >> 8) & 0xFF);
}

function u32le(buf, off)
{
    return (ord(buf, off)
        | (ord(buf, off + 1) << 8)
        | (ord(buf, off + 2) << 16)
        | (ord(buf, off + 3) << 24)) & 0xFFFFFFFF;
}

function cstr(s)
{
    if (!s) return "";
    let n = length(s);
    while (n > 0 && ord(s, n - 1) === 0) n--;
    return substr(s, 0, n);
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
// MeshCore boot handshake, queue polling, and channel discovery.
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
    log1("channel discovery request index=%d reason=%s\n", index, reason ?? "unknown");
    return sendCommand(CMD_GET_CHANNEL, chr(index & 0xff));
}

function requestAllChannels(reason)
{
    if (!channelDiscovery || !s) {
        return;
    }
    for (let i = 0; i <= MAX_CHANNEL_INDEX; i++) {
        requestChannelInfo(i, reason);
    }
}

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

function parseSelfInfo(payload)
{
    if (!payload || length(payload) < 36) {
        log1("parseSelfInfo: insufficient data (%d bytes)\n", length(payload) ?? 0);
        return null;
    }
    if (ord(payload, 0) !== RESP_SELF_INFO) {
        log1("parseSelfInfo: wrong response code (0x%02x)\n", ord(payload, 0));
        return null;
    }

    let nameStart = SELF_INFO_PUBKEY_OFFSET + SELF_INFO_PUBKEY_SIZE;
    const payloadLen = length(payload);
    while (nameStart < payloadLen) {
        const byte = ord(payload, nameStart);
        if ((byte >= 0x20 && byte <= 0x7E) || byte >= 0x80) break;
        nameStart++;
    }
    if (nameStart >= payloadLen) {
        log1("parseSelfInfo: no printable name found\n");
        return null;
    }

    let name = "";
    for (let i = nameStart; i < payloadLen; i++) {
        const byte = ord(payload, i);
        if (byte === 0) break;
        name += chr(byte);
    }

    log0("parseSelfInfo: device name = %s\n", name);
    return name;
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
    const ch = decodeChannelInfo(framePayload);
    if (!ch) {
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
        const dataLen = plen - 1;
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
            if (channelDiscovery) {
                requestAllChannels("self-info");
            }
            continue;
        }

        if (cmd === RESP_CHANNEL_INFO) {
            stats.responses_cached++;
            syncRequestInFlight = false;
            push(responses, { cmd: cmd, payload: framePayload });
            processChannelInfo(framePayload);
            continue;
        }

        if (!isDirectFrame(cmd) && !isGroupFrame(cmd)) {
            stats.early_drop_unknown_cmd++;
            syncRequestInFlight = false;
            log1("early-drop unknown cmd=0x%02x plen=%d\n", cmd, plen);
            maybeRequestNext("drop unknown");
            continue;
        }

        syncRequestInFlight = false;

        if (isDirectFrame(cmd)) {
            if (dataLen < TEXT_ENVELOPE_BYTES) {
                stats.early_drop_malformed_text++;
                log1("early-drop short direct plen=%d < %d\n", dataLen, TEXT_ENVELOPE_BYTES);
                maybeRequestNext("drop short direct");
                continue;
            }
            const tlen = ord(payload, 8);
            if (TEXT_ENVELOPE_BYTES + tlen > dataLen) {
                stats.early_drop_malformed_text++;
                log1("early-drop malformed direct tlen=%d plen=%d\n", tlen, dataLen);
                maybeRequestNext("drop malformed direct");
                continue;
            }
        }
        else if (isGroupFrame(cmd)) {
            if (dataLen < 5) {
                stats.early_drop_malformed_text++;
                log1("early-drop short group plen=%d < 5\n", dataLen);
                maybeRequestNext("drop short group");
                continue;
            }
        }

        push(frames, { cmd: cmd, payload: payload });
    }
}

function decodeTextFrame(cmd, payload)
{
    if (isDirectFrame(cmd)) {
        const fromId = u32le(payload, 0);
        const toId   = u32le(payload, 4);
        const tlen   = ord(payload, 8);
        const text   = cstr(substr(payload, 9, tlen));

        if (!length(text)) {
            log1("decode: empty direct text from=%08x\n", fromId);
            return null;
        }

        msgSeq = (msgSeq + 1) & 0xFFFFFFFF;
        const msg = {
            id:                   msgSeq,
            from:                 fromId,
            to:                   toId,
            rx_time:              time(),
            hop_limit:            1,
            transport:            "meshcore",
            backend:              "tcp_api",
            originating_callsign: callsign,
            namekey:              channelNamekey,
            data: {
                text_message: text
            },
            metadata: {
                is_group_message: false,
                identity_strength: "strong"
            }
        };

        log1("decoded DIRECT_MSG(0x07) from=%08x to=%08x text=%d bytes\n",
            fromId, toId, length(text));
        return msg;
    }

    if (isGroupFrame(cmd)) {
        const fromId = u32le(payload, 0);
        const groupSlot = ord(payload, 4);
        const text = cstr(substr(payload, 5));

        if (!length(text)) {
            log1("decode: empty group text from=%08x slot=%d\n", fromId, groupSlot);
            return null;
        }

        msgSeq = (msgSeq + 1) & 0xFFFFFFFF;
        const msg = {
            id:                   msgSeq,
            from:                 fromId,
            group_slot:           groupSlot,
            rx_time:              time(),
            hop_limit:            1,
            transport:            "meshcore",
            backend:              "tcp_api",
            originating_callsign: callsign,
            namekey:              channelNamekey,
            data: {
                text_message: text
            },
            metadata: {
                is_group_message: true,
                group_slot: groupSlot,
                identity_strength: "weak",
                symmetric_key: true,
                requires_slot_lookup: true
            }
        };

        log1("decoded CHANNEL_MSG(0x08) from=%08x slot=%d text=%d bytes\n",
            fromId, groupSlot, length(text));
        return msg;
    }

    log1("decode: unknown frame cmd=0x%02x\n", cmd);
    return null;
}

function popPending(reason)
{
    if (length(pendingRx) === 0) return null;
    const msg = shift(pendingRx);
    maybeRequestNext(reason ?? "pending delivered");
    return msg;
}

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
    log1("send: not implemented (msg.id=%s)\n", msg?.id);
    return false;
};

export function tick()
{
    if (enabled && !channelCreated && channel) {
        try {
            ensureRuntimePublicChannel();
        }
        catch (err) {
            log0("auto channel check error: %s\n", err);
            stats.early_drop_unknown_cmd++;
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
        requestAllChannels("refresh");
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
    const out = {
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
        last_rx_time: lastRxTime,
        last_cmd: lastCmd,
        syncing_messages: syncingMessages,
        sync_request_in_flight: syncRequestInFlight,
        sync_paused_backpressure: syncPausedBackpressure,
        channel_discovery: channelDiscovery,
        channel_discovery_requests: stats.channel_discovery_requests,
        channel_info_responses: stats.channel_info_responses,
        channels_discovered: stats.channels_discovered,
        channels_updated: stats.channels_updated
    };
    return out;
};

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
