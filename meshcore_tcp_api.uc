// =====================================================================
// meshcore_tcp_api.uc
// =====================================================================
//
// Crow MeshCore TCP Companion API backend.
//
// Connects natively to a MeshCore radio over TCP (default 127.0.0.1:4403)
// and speaks the MeshCore Companion Protocol — the same binary protocol
// used by MeshMonitor. This is NOT Meshtastic's port 4403 (which streams
// raw protobufs). MeshCore Companion is a structured, binary Command/
// Response protocol with asynchronous event frames:
//
//     [ Magic ][ CmdID ][ PayloadLen (2 bytes BE) ][ Payload ... ]
//
// Design pillars:
//
//   1. Non-blocking ucode socket integrated with Crow's timer-driven
//      recv/send loop (same shape as meshtastic_API.uc).
//   2. "Smart Accumulator" — Part 97 / FCC rules are enforced AT the buffer
//      level. Oversized frames, encrypted payload types, and unknown
//      command IDs are dropped from the TCP stream BEFORE allocating a
//      payload buffer, protecting OpenWrt RAM.
//   3. MeshMonitor-style boot handshake to subscribe the radio to
//      asynchronous TXT_MSG / GRP_TXT / ADVERT push events.
//   4. Reconnect backoff with stable state machine reset.
//   5. All decoded text messages routed through gatekeeper before AREDN.
//
// This backend is EXPERIMENTAL. It is not wired into router.uc by default.
// Enable via config:
//
//     "meshcore_tcp_api": {
//         "enabled": true,
//         "host": "127.0.0.1",
//         "port": 4403
//     }
//
// =====================================================================

import * as socket from "socket";
import * as timers from "timers";

// ---------------------------------------------------------------------
// Wire protocol constants
// ---------------------------------------------------------------------

const COMPANION_MAGIC          = 0x3E;   // '>' — MeshMonitor-observed sync byte
const HEADER_BYTES             = 4;       // magic(1) + cmd(1) + len(2)

// Maximum payload bytes we are willing to buffer for a single Companion
// frame. A real MeshCore text message + envelope is well under this.
// Anything larger is treated as glitch/attack and discarded WITHOUT
// allocating buffer space (Smart Accumulator rule 1).
const SMART_MAX_PAYLOAD        = 512;

// How many bytes to keep in the rolling resync window when we're
// searching for the next magic byte. Without this cap, a steady stream of
// garbage with no magic byte could grow tcpbuf without bound.
const RESYNC_BUFFER_CAP        = 4096;

// Async event command IDs (push frames from the radio)
const CMD_HELLO_RESP           = 0x80;
const CMD_TXT_MSG              = 0x81;   // direct/private cleartext text msg
const CMD_GRP_TXT              = 0x82;   // group/channel cleartext text msg
const CMD_ADVERT               = 0x83;   // node advertisement / discovery
const CMD_ENCRYPTED_DM         = 0x90;   // encrypted direct message (DROP)
const CMD_ENCRYPTED_BIN        = 0x91;   // encrypted binary blob   (DROP)

// Outgoing command IDs (host -> radio)
const CMD_HELLO                = 0x01;   // initial handshake
const CMD_SUBSCRIBE_EVENTS     = 0x02;   // subscribe to async TXT push

// Cleartext command IDs allowed past the early-drop gate.
const CLEARTEXT_COMMANDS = {
    [CMD_HELLO_RESP]:  true,
    [CMD_TXT_MSG]:     true,
    [CMD_GRP_TXT]:     true,
    [CMD_ADVERT]:      true
};

// Encrypted / non-compliant command IDs that are always early-dropped
// when Strict Gatekeeper is enabled, regardless of payload contents.
const PART97_BLOCKED_COMMANDS = {
    [CMD_ENCRYPTED_DM]:  true,
    [CMD_ENCRYPTED_BIN]: true
};

const DEFAULT_HOST             = "127.0.0.1";
const DEFAULT_PORT             = 4403;
const RECONNECT_INTERVAL       = 5;       // seconds
const SOCKET_READ_CHUNK        = 2048;

// ---------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------

let cfg              = null;
let enabled          = false;
let callsign         = null;
let router           = null;
let gatekeeper       = null;
let tcpHost          = null;
let tcpPort          = DEFAULT_PORT;

let s                = null;     // active socket handle (null = disconnected)
let tcpbuf           = "";       // TCP accumulator
let handshakeDone    = false;
let pendingRx        = [];       // decoded Crow message queue
let stats            = {
    connects: 0,
    disconnects: 0,
    frames_in: 0,
    frames_decoded: 0,
    early_drop_oversize: 0,
    early_drop_encrypted: 0,
    early_drop_unknown_cmd: 0,
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
// Small binary helpers
// ---------------------------------------------------------------------

function be16(buf, off)
{
    return ((ord(buf, off) << 8) & 0xFF00) | (ord(buf, off + 1) & 0xFF);
}

function pack_be16(n)
{
    return chr((n >> 8) & 0xFF) + chr(n & 0xFF);
}

// Strip trailing NULs from a C-style string payload field.
function cstr(s)
{
    if (!s) return "";
    let n = length(s);
    while (n > 0 && ord(s, n - 1) === 0) {
        n--;
    }
    return substr(s, 0, n);
}

// ---------------------------------------------------------------------
// Socket lifecycle
// ---------------------------------------------------------------------

function resetState()
{
    tcpbuf = "";
    handshakeDone = false;
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
// MeshMonitor-style boot handshake
// ---------------------------------------------------------------------
//
// On connect, send:
//   [ MAGIC ][ CMD_HELLO         ][ len=0 ]
//   [ MAGIC ][ CMD_SUBSCRIBE_EVT ][ len=0 ]
//
// This is what wakes the Companion interface and causes the radio to
// autonomously push TXT_MSG / GRP_TXT frames over the socket without
// polling.

function buildFrame(cmd, payload)
{
    payload = payload ?? "";
    return chr(COMPANION_MAGIC) + chr(cmd & 0xFF) + pack_be16(length(payload)) + payload;
}

function sendBootHandshake()
{
    if (!s) return;
    try {
        s.send(buildFrame(CMD_HELLO, ""));
        s.send(buildFrame(CMD_SUBSCRIBE_EVENTS, ""));
        handshakeDone = true;
        log1("handshake sent (HELLO + SUBSCRIBE_EVENTS)\n");
    }
    catch (_) {
        closeSocket("handshake send failed: " + socket.error());
    }
}

// ---------------------------------------------------------------------
// The "Smart Accumulator"
// ---------------------------------------------------------------------
//
// Pulls fully-formed Companion frames out of tcpbuf. Applies Part 97 /
// memory-safety rules BEFORE allocating per-frame payload buffers:
//
//   * Oversize early drop: frame length > SMART_MAX_PAYLOAD.
//   * Encrypted early drop: command ID in PART97_BLOCKED_COMMANDS while
//     Strict Gatekeeper is enabled.
//   * Unknown-command early drop: command ID outside CLEARTEXT_COMMANDS.
//
// Returns an array of { cmd, payload } records ready for decoding.
//
// IMPORTANT: when an early-drop fires, we *don't* keep accumulating
// pending bytes — we advance the buffer past the bad frame's bounds
// (or, if the payload hasn't arrived yet, mark how many bytes to skip
// from future reads). This is the "flush from the wire" behavior the
// design plan calls for.

let pendingSkip = 0;   // bytes still to discard from incoming stream

function smartAccumulate(data)
{
    const frames = [];

    // Discard any in-flight skip bytes first (continuation of a previous
    // early-drop whose payload hadn't fully arrived yet).
    if (pendingSkip > 0 && length(data) > 0) {
        const drop = pendingSkip < length(data) ? pendingSkip : length(data);
        data = substr(data, drop);
        pendingSkip -= drop;
        if (pendingSkip > 0) {
            return frames;
        }
    }

    tcpbuf += data;
    const strictOn = gatekeeper?.isEnabled() === true;

    for (;;) {
        // 1. Resync: find next magic byte.
        let start = -1;
        const blen = length(tcpbuf);
        for (let i = 0; i < blen; i++) {
            if (ord(tcpbuf, i) === COMPANION_MAGIC) {
                start = i;
                break;
            }
        }
        if (start < 0) {
            // Cap the resync window so a glitch-storm can't grow tcpbuf
            // unbounded.
            if (blen > RESYNC_BUFFER_CAP) {
                stats.resync_skips++;
                log1("resync: dropped %d bytes of pre-magic garbage\n", blen);
                tcpbuf = "";
            }
            return frames;
        }
        if (start > 0) {
            stats.resync_skips++;
            log1("resync: skipped %d bytes before magic\n", start);
            tcpbuf = substr(tcpbuf, start);
        }

        // 2. Need a full header?
        if (length(tcpbuf) < HEADER_BYTES) {
            return frames;
        }

        const cmd = ord(tcpbuf, 1);
        const plen = be16(tcpbuf, 2);

        // 3. Smart Accumulator gates — applied BEFORE buffering payload.

        // 3a. Oversized payload kill switch.
        if (plen > SMART_MAX_PAYLOAD) {
            stats.early_drop_oversize++;
            log1("early-drop oversize cmd=0x%02x plen=%d > %d\n",
                cmd, plen, SMART_MAX_PAYLOAD);
            // We can't trust the rest of the stream — advance past header
            // and arrange to discard the claimed payload as it arrives.
            tcpbuf = substr(tcpbuf, HEADER_BYTES);
            pendingSkip = plen;
            // Apply pendingSkip to whatever's already in tcpbuf.
            if (pendingSkip > 0 && length(tcpbuf) > 0) {
                const drop = pendingSkip < length(tcpbuf) ? pendingSkip : length(tcpbuf);
                tcpbuf = substr(tcpbuf, drop);
                pendingSkip -= drop;
            }
            continue;
        }

        // 3b. Encrypted / blocked command early drop under Strict mode.
        if (strictOn && PART97_BLOCKED_COMMANDS[cmd]) {
            stats.early_drop_encrypted++;
            log1("early-drop encrypted cmd=0x%02x plen=%d (Part 97)\n", cmd, plen);
            // Drop header + payload from buffer.
            if (length(tcpbuf) >= HEADER_BYTES + plen) {
                tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
            }
            else {
                pendingSkip = HEADER_BYTES + plen - length(tcpbuf);
                tcpbuf = "";
            }
            continue;
        }

        // 3c. Unknown / unsupported command early drop.
        if (!CLEARTEXT_COMMANDS[cmd]) {
            stats.early_drop_unknown_cmd++;
            log1("early-drop unknown cmd=0x%02x plen=%d\n", cmd, plen);
            if (length(tcpbuf) >= HEADER_BYTES + plen) {
                tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
            }
            else {
                pendingSkip = HEADER_BYTES + plen - length(tcpbuf);
                tcpbuf = "";
            }
            continue;
        }

        // 4. Need full payload? If not, leave it in tcpbuf and wait for
        //    next read. This is the fragmentation-safe wait.
        if (length(tcpbuf) < HEADER_BYTES + plen) {
            return frames;
        }

        // 5. Emit the validated frame.
        const payload = substr(tcpbuf, HEADER_BYTES, plen);
        tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
        stats.frames_in++;
        push(frames, { cmd: cmd, payload: payload });
    }
}

// ---------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------
//
// MeshCore Companion TXT_MSG / GRP_TXT payload (cleartext form):
//
//   Off  Size  Field
//   0    4     sender node id      (uint32 LE)
//   4    4     target node id      (uint32 LE)   (0 = broadcast/group)
//   8    1     text length (n)
//   9    n     UTF-8 text bytes
//
// Anything else is decoded best-effort. Unknown shapes return null and
// are logged.

function readU32LE(buf, off)
{
    if (off + 4 > length(buf)) return null;
    return (ord(buf, off)
        | (ord(buf, off + 1) << 8)
        | (ord(buf, off + 2) << 16)
        | (ord(buf, off + 3) << 24)) & 0xFFFFFFFF;
}

function decodeTextFrame(cmd, payload)
{
    if (length(payload) < 9) {
        log1("decode: short text payload cmd=0x%02x len=%d\n", cmd, length(payload));
        return null;
    }
    const fromId = readU32LE(payload, 0);
    const toId   = readU32LE(payload, 4);
    const tlen   = ord(payload, 8);
    if (9 + tlen > length(payload)) {
        log1("decode: truncated text len=%d payloadlen=%d\n", tlen, length(payload));
        return null;
    }
    const text = cstr(substr(payload, 9, tlen));
    if (!length(text)) {
        log1("decode: empty text from=%08x\n", fromId);
        return null;
    }

    const msg = {
        transport:            "meshcore",
        backend:              "tcp_api",
        from:                 fromId,
        to:                   toId,
        rx_time:              time(),
        hop_limit:            1,
        originating_callsign: callsign,
        data: {
            text_message: text
        }
    };
    if (cmd === CMD_GRP_TXT) {
        msg.is_group = true;
    }
    log1("decoded %s from=%08x to=%08x text=%d bytes\n",
        cmd === CMD_GRP_TXT ? "GRP_TXT" : "TXT_MSG",
        fromId, toId, length(text));
    return msg;
}

function dispatchFrame(frame)
{
    switch (frame.cmd) {
        case CMD_HELLO_RESP:
            log1("HELLO_RESP received (len=%d)\n", length(frame.payload));
            return null;
        case CMD_ADVERT:
            log1("ADVERT received (len=%d)\n", length(frame.payload));
            return null;
        case CMD_TXT_MSG:
        case CMD_GRP_TXT:
            return decodeTextFrame(frame.cmd, frame.payload);
    }
    return null;
}

// ---------------------------------------------------------------------
// Public lifecycle API (mirrors meshtastic_API.uc)
// ---------------------------------------------------------------------

export function setup(config)
{
    cfg = config.meshcore_tcp_api;
    if (!cfg || cfg.enabled === false) {
        return;
    }
    enabled = true;

    callsign   = config.callsign;
    router     = config.router;
    gatekeeper = config._gatekeeper;
    tcpHost    = cfg.host ?? DEFAULT_HOST;
    tcpPort    = cfg.port ?? DEFAULT_PORT;

    s = openTcp();
    if (s) {
        sendBootHandshake();
    }
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
    // Drain any already-decoded messages first.
    if (length(pendingRx) > 0) {
        return shift(pendingRx);
    }

    // Reconnect path.
    if (!s && timers.tick("meshcore_tcp_api.reconnect")) {
        s = openTcp();
        if (s) {
            sendBootHandshake();
        }
    }
    if (!s) return null;

    const data = readSocket();
    if (!data) return null;

    const frames = smartAccumulate(data);
    for (let i = 0; i < length(frames); i++) {
        const msg = dispatchFrame(frames[i]);
        if (!msg) continue;

        // Hand decoded text messages to the gatekeeper for callsign /
        // whitelist / annotation enforcement. The gatekeeper returns null
        // on drop, or the (possibly rewritten) message on pass.
        if (gatekeeper && typeof(gatekeeper.filterInboundBridge) === "function") {
            const gated = gatekeeper.filterInboundBridge(msg);
            if (!gated) continue;
            stats.frames_decoded++;
            push(pendingRx, gated);
        }
        else {
            stats.frames_decoded++;
            push(pendingRx, msg);
        }
    }

    if (length(pendingRx) > 0) {
        return shift(pendingRx);
    }
    return null;
};

export function send(msg)
{
    // Outbound send is not yet implemented for the TCP Companion backend.
    // Production outbound continues via the existing meshcore.uc UDP path.
    log1("send: not implemented (msg.id=%s)\n", msg?.id);
    return false;
};

// ---------------------------------------------------------------------
// Test/introspection hooks (used by tests/test_meshcore_tcp_api.uc).
// These are intentionally side-door entry points so the buffer state
// machine can be exercised without a real socket.
// ---------------------------------------------------------------------

export function _test_inject(data, gatekeeperShim)
{
    if (gatekeeperShim !== null && gatekeeperShim !== undefined) {
        gatekeeper = gatekeeperShim;
    }
    return smartAccumulate(data);
};

export function _test_reset()
{
    resetState();
    pendingSkip = 0;
    for (let k in stats) {
        stats[k] = 0;
    }
};

export function _test_stats()
{
    return stats;
};

export function _test_build_frame(cmd, payload)
{
    return buildFrame(cmd, payload);
};
