// =====================================================================
// meshcore_tcp_api.uc
// =====================================================================
//
// Crow MeshCore TCP / Serial-WiFi backend — text-message bridge scaffold.
//
// This file uses the stock MeshCore serial/Wi-Fi outer framing:
//
//     Radio -> client: [ '>' ][ length LSB ][ length MSB ][ frame payload ]
//     Client -> radio: [ '<' ][ length LSB ][ length MSB ][ frame payload ]
//
// The frame payload begins with the MeshCore command/response/push code.
// This is NOT Meshtastic's port 4403 protocol.
//
// Receive model:
//
//     0x83 PUSH_CODE_MSG_WAITING
//       -> client sends CMD_SYNC_NEXT_MESSAGE (0x0A)
//       -> radio returns a queued message response:
//          0x07 / 0x08 older direct/channel response
//          0x10 / 0x11 newer v3 direct/channel response
//
// Outbound text sending through this backend is still not implemented;
// production outbound MeshCore traffic continues through meshcore.uc.
//
// =====================================================================

import * as socket from "socket";
import * as timers from "timers";

// ---------------------------------------------------------------------
// Wire protocol constants
// ---------------------------------------------------------------------

const FRAME_FROM_RADIO          = 0x3E;   // '>'
const FRAME_TO_RADIO            = 0x3C;   // '<'
const HEADER_BYTES              = 3;      // marker(1) + len_le(2)

const SMART_MAX_PAYLOAD         = 256;
const RESYNC_BUFFER_CAP         = 4096;

const PUSH_CODE_MSG_WAITING     = 0x83;
const CMD_SYNC_NEXT_MESSAGE     = 0x0A;
const CMD_GET_CHANNEL           = 0x1F;

const RESP_DIRECT_MSG_RECV      = 0x07;
const RESP_CHANNEL_MSG_RECV     = 0x08;
const RESP_DIRECT_MSG_RECV_V3   = 0x10;
const RESP_CHANNEL_MSG_RECV_V3  = 0x11;
const RESP_CHANNEL_INFO         = 0x12;

const CMD_ENCRYPTED_DM          = 0x90;
const CMD_ENCRYPTED_BIN         = 0x91;

const PART97_BLOCKED_COMMANDS = {
    [CMD_ENCRYPTED_DM]:  true,
    [CMD_ENCRYPTED_BIN]: true
};

const DEFAULT_HOST              = "127.0.0.1";
const DEFAULT_PORT              = 4403;
const RECONNECT_INTERVAL        = 5;
const SOCKET_READ_CHUNK         = 2048;

const DIRECT_TEXT_ENVELOPE_BYTES = 9;     // from(4) + to(4) + text_len(1)
const GROUP_TEXT_ENVELOPE_BYTES  = 5;     // from(4) + slot(1)

// ---------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------

let cfg              = null;
let enabled          = false;
let callsign         = null;
let router           = null;
let tcpHost          = null;
let tcpPort          = DEFAULT_PORT;
let strictHook       = null;

let s                = null;
let tcpbuf           = "";
let pendingSkip      = 0;
let pendingRx        = [];
let responseQueue    = [];
let msgSeq           = 0;

let stats            = {
    connects: 0,
    disconnects: 0,
    frames_in: 0,
    frames_decoded: 0,
    commands_sent: 0,
    message_waiting: 0,
    responses_cached: 0,
    early_drop_oversize: 0,
    early_drop_encrypted: 0,
    early_drop_unknown_cmd: 0,
    early_drop_malformed_text: 0,
    resync_skips: 0
};

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

function isMessageResponse(code)
{
    return code === RESP_DIRECT_MSG_RECV
        || code === RESP_CHANNEL_MSG_RECV
        || code === RESP_DIRECT_MSG_RECV_V3
        || code === RESP_CHANNEL_MSG_RECV_V3;
}

function isGroupMessageResponse(code)
{
    return code === RESP_CHANNEL_MSG_RECV
        || code === RESP_CHANNEL_MSG_RECV_V3;
}

function isDirectMessageResponse(code)
{
    return code === RESP_DIRECT_MSG_RECV
        || code === RESP_DIRECT_MSG_RECV_V3;
}

// ---------------------------------------------------------------------
// Socket lifecycle
// ---------------------------------------------------------------------

function resetState()
{
    tcpbuf = "";
    pendingSkip = 0;
}

function closeSocket(reason)
{
    if (s) {
        log0("disconnect %s\n", reason ?? "");
        stats.disconnects++;
        try { s.close(); } catch (_) {}
    }
    s = null;
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
        ns.connect({ address: tcpHost, port: tcpPort });
        log0("connected tcp companion %s:%d\n", tcpHost, tcpPort);
        stats.connects++;
        return ns;
    }
    catch (_) {
        log0("tcp connect failed %s:%d: %s\n", tcpHost, tcpPort, socket.error());
        return null;
    }
}

// ---------------------------------------------------------------------
// Stock MeshCore frame construction.
// ---------------------------------------------------------------------

function buildFramePayload(cmd, payload)
{
    payload = payload ?? "";
    return chr(cmd & 0xFF) + payload;
}

function buildFrame(cmd, payload)
{
    const framePayload = buildFramePayload(cmd, payload);
    return chr(FRAME_TO_RADIO) + pack_le16(length(framePayload)) + framePayload;
}

export function sendCommand(cmd, payload)
{
    if (!s) {
        log1("sendCommand: socket not connected cmd=0x%02x\n", cmd);
        return false;
    }
    try {
        s.send(buildFrame(cmd, payload ?? ""));
        stats.commands_sent++;
        log1("sendCommand: cmd=0x%02x payload=%d\n", cmd, length(payload ?? ""));
        return true;
    }
    catch (_) {
        closeSocket("sendCommand failed: " + socket.error());
        return false;
    }
}

function sendBootHandshake()
{
    if (!s) return;
    sendCommand(0x01, "");
}

function requestNextMessage()
{
    sendCommand(CMD_SYNC_NEXT_MESSAGE, "");
}

// ---------------------------------------------------------------------
// Smart Accumulator
// ---------------------------------------------------------------------

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
                    log1("resync: dropped %d bytes of pre-frame garbage\n", blen);
                    tcpbuf = "";
                }
                return frames;
            }
            stats.resync_skips++;
            log1("resync: skipped %d bytes before frame marker\n", start);
            tcpbuf = substr(tcpbuf, start);
            continue;
        }

        if (blen < HEADER_BYTES) return frames;

        const plen = le16(tcpbuf, 1);

        if (plen < 1) {
            stats.early_drop_malformed_text++;
            tcpbuf = substr(tcpbuf, HEADER_BYTES);
            continue;
        }

        if (plen > SMART_MAX_PAYLOAD) {
            stats.early_drop_oversize++;
            log1("early-drop oversize plen=%d > %d\n", plen, SMART_MAX_PAYLOAD);
            advance(HEADER_BYTES, plen);
            continue;
        }

        if (blen < HEADER_BYTES + plen) return frames;

        const framePayload = substr(tcpbuf, HEADER_BYTES, plen);
        tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);

        const code = ord(framePayload, 0);
        const payload = substr(framePayload, 1);
        stats.frames_in++;

        if (code === PUSH_CODE_MSG_WAITING) {
            stats.message_waiting++;
            log1("message waiting push received; requesting next queued message\n");
            requestNextMessage();
            continue;
        }

        if (strictOn && PART97_BLOCKED_COMMANDS[code]) {
            stats.early_drop_encrypted++;
            log1("early-drop encrypted code=0x%02x plen=%d (Part 97)\n", code, plen);
            continue;
        }

        if (isMessageResponse(code)) {
            if (!validTextPayload(code, payload)) {
                stats.early_drop_malformed_text++;
                continue;
            }
            push(frames, { cmd: code, payload: payload });
            continue;
        }

        if (code === RESP_CHANNEL_INFO) {
            stats.responses_cached++;
            push(responseQueue, { cmd: code, payload: framePayload });
            continue;
        }

        stats.early_drop_unknown_cmd++;
        log1("early-drop unknown code=0x%02x plen=%d\n", code, plen);
    }
}

function validTextPayload(code, payload)
{
    const plen = length(payload);
    if (isDirectMessageResponse(code)) {
        if (plen < DIRECT_TEXT_ENVELOPE_BYTES) {
            log1("early-drop short direct plen=%d < %d\n", plen, DIRECT_TEXT_ENVELOPE_BYTES);
            return false;
        }
        const tlen = ord(payload, 8);
        if (DIRECT_TEXT_ENVELOPE_BYTES + tlen > plen) {
            log1("early-drop malformed direct tlen=%d plen=%d\n", tlen, plen);
            return false;
        }
        return true;
    }

    if (isGroupMessageResponse(code)) {
        if (plen < GROUP_TEXT_ENVELOPE_BYTES) {
            log1("early-drop short group plen=%d < %d\n", plen, GROUP_TEXT_ENVELOPE_BYTES);
            return false;
        }
        return true;
    }

    return false;
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

// ---------------------------------------------------------------------
// Decoder — queued message responses.
// ---------------------------------------------------------------------

function decodeTextFrame(cmd, payload)
{
    if (isDirectMessageResponse(cmd)) {
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
            data: {
                text_message: text
            },
            metadata: {
                is_group_message: false,
                identity_strength: "strong",
                meshcore_response_code: cmd
            }
        };

        log1("decoded DIRECT_MSG(0x%02x) from=%08x to=%08x text=%d bytes\n",
            cmd, fromId, toId, length(text));
        return msg;

    } else if (isGroupMessageResponse(cmd)) {
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
            data: {
                text_message: text
            },
            metadata: {
                is_group_message: true,
                group_slot: groupSlot,
                identity_strength: "weak",
                symmetric_key: true,
                requires_slot_lookup: true,
                meshcore_response_code: cmd
            }
        };

        log1("decoded CHANNEL_MSG(0x%02x) from=%08x slot=%d text=%d bytes\n",
            cmd, fromId, groupSlot, length(text));
        return msg;
    }

    log1("decode: unknown frame cmd=0x%02x\n", cmd);
    return null;
}

// ---------------------------------------------------------------------
// Public lifecycle API
// ---------------------------------------------------------------------

export function setup(config)
{
    cfg = config.meshcore_tcp_api;
    if (!cfg || cfg.enabled === false) {
        return;
    }
    enabled = true;

    callsign = config.callsign;
    router   = config.router;
    tcpHost  = cfg.host ?? DEFAULT_HOST;
    tcpPort  = cfg.port ?? DEFAULT_PORT;

    const gk = config._gatekeeper;
    strictHook = gk && typeof(gk.isEnabled) === "function"
        ? function () { return gk.isEnabled() === true; }
        : null;

    s = openTcp();
    if (s) sendBootHandshake();
    timers.setInterval("meshcore_tcp_api.reconnect", RECONNECT_INTERVAL);
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
        return s.recv(SOCKET_READ_CHUNK);
    }
    catch (_) {
        closeSocket(socket.error());
        return null;
    }
}

export function recv()
{
    if (length(pendingRx) > 0) return shift(pendingRx);

    if (!s && timers.tick("meshcore_tcp_api.reconnect")) {
        s = openTcp();
        if (s) sendBootHandshake();
    }
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

    if (length(pendingRx) > 0) return shift(pendingRx);
    return null;
};

export function send(msg)
{
    log1("send: not implemented (msg.id=%s)\n", msg?.id);
    return false;
};

export function takeResponse(cmd)
{
    const keep = [];
    let found = null;
    for (let i = 0; i < length(responseQueue); i++) {
        const r = responseQueue[i];
        if (!found && r.cmd === cmd) {
            found = r;
        }
        else {
            push(keep, r);
        }
    }
    responseQueue = keep;
    return found;
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
    responseQueue = [];
    msgSeq = 0;
    for (let k in stats) stats[k] = 0;
};

export function _test_stats()
{
    return stats;
};

export function _test_build_frame(cmd, payload)
{
    const framePayload = buildFramePayload(cmd, payload ?? "");
    return chr(FRAME_FROM_RADIO) + pack_le16(length(framePayload)) + framePayload;
};

export function _test_build_command(cmd, payload)
{
    return buildFrame(cmd, payload ?? "");
};

export function _test_take_response(cmd)
{
    return takeResponse(cmd);
};
