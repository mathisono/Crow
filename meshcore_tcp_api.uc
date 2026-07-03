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
//     [ Magic=0x3E ][ CmdID ][ PayloadLen (2 bytes BE) ][ Payload ... ]
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
//   3. MeshMonitor-style boot handshake — HELLO + SUBSCRIBE_EVENTS,
//      fire-and-forget. The response is consumed by the unknown-cmd
//      gate (we don't need to inspect it).
//   4. Reconnect backoff with stable state-machine reset.
//   5. Decoded messages are queued raw; router.uc runs the canonical
//      gatekeeper.filterInboundBridge() pass (no double-filtering).
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
import * as channel from "channel";
import * as fs from "fs";

// ---------------------------------------------------------------------
// Wire protocol constants
// ---------------------------------------------------------------------

const COMPANION_MAGIC          = 0x3E;   // '>' — MeshMonitor-observed sync byte
const HEADER_BYTES             = 4;       // magic(1) + cmd(1) + len(2)

// Hard ceiling on per-frame payload bytes we will buffer. MeshCore text
// MTU is ~150 bytes; with the 9-byte text envelope (from/to/len) the
// observed maximum is ~159. 256 gives headroom for future variants while
// still being a small RAM target. Anything bigger is dropped from the
// wire (Smart Accumulator rule 1).
const SMART_MAX_PAYLOAD        = 256;

// Cap the rolling resync window. Without this, a steady stream of
// garbage without a magic byte could grow tcpbuf without bound.
const RESYNC_BUFFER_CAP        = 4096;

// Async event command IDs we actually emit Crow messages for.
// CORRECTED (per Mathison): Frame 0x07 is direct, 0x08 is group
const CMD_DIRECT_MSG_RECV      = 0x07;   // direct/private cleartext text msg
const CMD_CHANNEL_MSG_RECV     = 0x08;   // group/channel cleartext text msg

// Outgoing command IDs (host -> radio). Sent once at connect, never
// inspected on return.
const CMD_HELLO                = 0x01;
const CMD_SUBSCRIBE_EVENTS     = 0x02;

// Self-info response from radio (triggered by HELLO)
const RESP_SELF_INFO           = 0x05;   // Device info: public key + name
const SELF_INFO_PUBKEY_SIZE    = 32;     // Ed25519 public key
const SELF_INFO_PUBKEY_OFFSET  = 1;      // Right after response code

// Event codes that are NOT message frames (to be explicitly skipped)
const PUSH_CODE_SEND_CONFIRMED = 0x82;   // Ack/confirmation (NOT group messages!)

// Encrypted / non-compliant command IDs that are always early-dropped
// when Strict Gatekeeper is enabled, regardless of payload contents.
// (Without strict mode, the unknown-cmd gate catches them too — strict
// mode just gives them their own stat bucket.)
const CMD_ENCRYPTED_DM         = 0x90;
const CMD_ENCRYPTED_BIN        = 0x91;

const PART97_BLOCKED_COMMANDS = {
    [CMD_ENCRYPTED_DM]:  true,
    [CMD_ENCRYPTED_BIN]: true
};

const DEFAULT_HOST             = "127.0.0.1";
const DEFAULT_PORT             = 4403;
const RECONNECT_INTERVAL       = 5;       // seconds
const SOCKET_READ_CHUNK        = 2048;

// Text frame envelope: 4-byte from + 4-byte to + 1-byte length.
const TEXT_ENVELOPE_BYTES      = 9;

// ---------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------

let cfg              = null;
let rootConfig       = null;
export let enabled   = false;
export let channelNamekey = null; // "<device> og==" — created on first tick
let deviceName       = null;     // device name from config
let channelCreated   = false;    // one-shot flag for lazy channel init
let callsign         = null;
let router           = null;
let tcpHost          = null;
let tcpPort          = DEFAULT_PORT;
let strictHook       = null;     // function(): boolean   — cached strict-mode probe

let s                = null;     // active socket handle (null = disconnected)
let tcpbuf           = "";       // TCP accumulator
let pendingSkip      = 0;        // bytes still to discard from incoming stream
let pendingRx        = [];       // decoded Crow message queue
let msgSeq           = 0;        // monotonic local message id

let stats            = {
    connects: 0,
    disconnects: 0,
    frames_in: 0,
    frames_decoded: 0,
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

function be16(buf, off)
{
    return ((ord(buf, off) << 8) & 0xFF00) | (ord(buf, off + 1) & 0xFF);
}

function pack_be16(n)
{
    return chr((n >> 8) & 0xFF) + chr(n & 0xFF);
}

function u32le(buf, off)
{
    return (ord(buf, off)
        | (ord(buf, off + 1) << 8)
        | (ord(buf, off + 2) << 16)
        | (ord(buf, off + 3) << 24)) & 0xFFFFFFFF;
}

// Strip trailing NULs from a C-style string payload field.
function cstr(s)
{
    if (!s) return "";
    let n = length(s);
    while (n > 0 && ord(s, n - 1) === 0) n--;
    return substr(s, 0, n);
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
// MeshCore boot handshake — fire-and-forget.
//
// CORRECTED (per Mathison): Auto-push model — no subscription mask needed.
// The radio autonomously pushes direct (0x07) and group (0x08) frames
// for all programmed groups. No SUBSCRIBE_EVENTS needed.
//
// Send only:
//   [ MAGIC ][ CMD_HELLO ][ len=0 ]
//
// The HELLO response (if any) is consumed by the unknown-cmd gate —
// we don't need to validate it for routing. Groups must be programmed
// into the radio's memory slots (0-7) via CMD_SET_CHANNEL.
// ---------------------------------------------------------------------

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
        // CORRECTED: No SUBSCRIBE_EVENTS needed (auto-push model)
        log1("handshake sent (HELLO)\n");
        log1("  Radio will auto-push: 0x07=Direct msg, 0x08=Group msg\n");
    }
    catch (_) {
        closeSocket("handshake send failed: " + socket.error());
    }
}

// ---------------------------------------------------------------------
// advance() — skip past rejected frames in the TCP buffer
// ---------------------------------------------------------------------

// Advance past a rejected frame. If the payload hasn't fully arrived
// yet, arrange to discard the remainder from future socket reads.
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


// -----
// parseSelfInfo() — Extract device name from RESP_SELF_INFO (0x05)
// =====================================================================
//
// MeshCore sends this immediately after HELLO. Payload structure:
//
//   Byte 0:      0x05 (response code)
//   Bytes 1-32:  Ed25519 public key (32 bytes)
//   Bytes 33-34: MAC/Hardware hash (2 bytes in v1, reserved for 4 in v2)
//   Byte 35:     Node Role/Type
//   Bytes 36+:   Node Name (UTF-8, null-padded, up to 32 bytes)
//
// Returns device name (string) or null on error.
// Uses safe scanning: skip known fixed fields, scan for first printable
// character, then read until null terminator or end of payload.
// =====================================================================

function parseSelfInfo(payload)
{
    if (!payload || length(payload) < 36) {
        log1("parseSelfInfo: insufficient data (%d bytes)\n", 
             length(payload) ?? 0);
        return null;
    }
    
    // Verify response code
    if (ord(payload, 0) !== RESP_SELF_INFO) {
        log1("parseSelfInfo: wrong response code (0x%02x)\n", 
             ord(payload, 0));
        return null;
    }
    
    // Safe name extraction:
    // Skip the first 33 bytes (response code + 32-byte public key)
    // Then scan for first printable ASCII character
    let nameStart = SELF_INFO_PUBKEY_OFFSET + SELF_INFO_PUBKEY_SIZE; // = 33
    const payloadLen = length(payload);
    
    // Skip non-printable bytes (MAC size, role/type, padding)
    while (nameStart < payloadLen) {
        const byte = ord(payload, nameStart);
        // Accept printable ASCII (0x20-0x7E) and UTF-8 high bytes (0x80+)
        if ((byte >= 0x20 && byte <= 0x7E) || byte >= 0x80) {
            break;
        }
        nameStart++;
    }
    
    if (nameStart >= payloadLen) {
        log1("parseSelfInfo: no printable name found\n");
        return null;
    }
    
    // Extract name until null terminator or end of payload
    let name = "";
    for (let i = nameStart; i < payloadLen; i++) {
        const byte = ord(payload, i);
        if (byte === 0) break;  // Stop at null terminator
        name += chr(byte);
    }
    
    log0("parseSelfInfo: device name = %s\n", name);
    return name;
}

// ---------------------------------------------------------------------
// The "Smart Accumulator"
// ---------------------------------------------------------------------
//
// Pulls fully-formed Companion frames out of tcpbuf, but only for
// commands we actually decode (TXT_MSG / GRP_TXT). Everything else is
// dropped from the wire without payload allocation:
//
//   * Oversize early-drop  — frame length > SMART_MAX_PAYLOAD.
//   * Encrypted early-drop — cmd in PART97_BLOCKED_COMMANDS when strict.
//   * Unknown-cmd drop     — cmd not in { TXT_MSG, GRP_TXT }.
//   * Malformed-text drop  — text-length byte is inconsistent with plen.
//
// When an early-drop fires mid-stream (payload not yet fully arrived),
// `pendingSkip` records how many bytes to discard from future reads.
//
// Returns an array of { cmd, payload } records ready for decoding.

function smartAccumulate(data)
{
    const frames = [];

    // 1. Discard any in-flight skip bytes first.
    if (pendingSkip > 0 && length(data) > 0) {
        const drop = pendingSkip < length(data) ? pendingSkip : length(data);
        data = substr(data, drop);
        pendingSkip -= drop;
        if (pendingSkip > 0) return frames;
    }

    if (length(data) > 0) {
        tcpbuf += data;
    }

    // Cache the strict-mode probe once per inject — strict-mode flips
    // rarely, and re-calling it inside the loop is wasted work.
    const strictOn = strictHook ? strictHook() : false;

    for (;;) {
        const blen = length(tcpbuf);
        if (blen === 0) return frames;

        // 2. Resync: find next magic byte.
        if (ord(tcpbuf, 0) !== COMPANION_MAGIC) {
            let start = -1;
            for (let i = 1; i < blen; i++) {
                if (ord(tcpbuf, i) === COMPANION_MAGIC) { start = i; break; }
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

        // 3. Need a full header before any further decisions.
        if (blen < HEADER_BYTES) return frames;

        const cmd  = ord(tcpbuf, 1);
        const plen = be16(tcpbuf, 2);

        // ----- Smart Accumulator gates (BEFORE payload allocation) -----

        // 3a. Oversize kill switch.
        if (plen > SMART_MAX_PAYLOAD) {
            stats.early_drop_oversize++;
            log1("early-drop oversize cmd=0x%02x plen=%d > %d\n",
                cmd, plen, SMART_MAX_PAYLOAD);
            advance(HEADER_BYTES, plen);
            continue;
        }

        // 3b. Encrypted / blocked command early drop under Strict mode.
        if (strictOn && PART97_BLOCKED_COMMANDS[cmd]) {
            stats.early_drop_encrypted++;
            log1("early-drop encrypted cmd=0x%02x plen=%d (Part 97)\n", cmd, plen);
            advance(HEADER_BYTES, plen);
            continue;
        }

        // 3c. EXCEPTION: RESP_SELF_INFO (0x05) is handled specially — we intercept it
        //     to extract the device name for auto-channel creation, but DON'T queue it
        //     as a message.
        if (cmd === RESP_SELF_INFO) {
            if (blen < HEADER_BYTES + plen) return frames;  // Wait for full payload
            const payload = substr(tcpbuf, HEADER_BYTES, plen);
            tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
            
            const name = parseSelfInfo(payload);
            if (name) {
                deviceName = name;  // Capture for channel creation
            }
            continue;
        }

        // 3d. Anything outside { DIRECT_MSG_RECV, CHANNEL_MSG_RECV } is dropped without
        //     decode. This catches HELLO_RESP, ADVERT, SEND_CONFIRMED (0x82),
        //     unencrypted DMs of unknown shape, vendor extensions, and (with strict OFF)
        //     the encrypted commands too.
        if (cmd !== CMD_DIRECT_MSG_RECV && cmd !== CMD_CHANNEL_MSG_RECV) {
            stats.early_drop_unknown_cmd++;
            log1("early-drop unknown cmd=0x%02x plen=%d\n", cmd, plen);
            advance(HEADER_BYTES, plen);
            continue;
        }

        // 4. Wait for full payload (fragmentation-safe).
        if (blen < HEADER_BYTES + plen) return frames;

        // 5. Inline text-envelope sanity check (frame-type dependent).
        //    CORRECTED per Mathison: Direct and group frames have different structures.
        if (cmd === CMD_DIRECT_MSG_RECV) {
            // Direct: sender(4) + recipient(4) + text_len(1) + text
            if (plen < TEXT_ENVELOPE_BYTES) {
                stats.early_drop_malformed_text++;
                log1("early-drop short direct plen=%d < %d\n", plen, TEXT_ENVELOPE_BYTES);
                tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
                continue;
            }
            const tlen = ord(tcpbuf, HEADER_BYTES + 8);
            if (TEXT_ENVELOPE_BYTES + tlen > plen) {
                stats.early_drop_malformed_text++;
                log1("early-drop malformed direct tlen=%d plen=%d\n", tlen, plen);
                tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
                continue;
            }
        } else if (cmd === CMD_CHANNEL_MSG_RECV) {
            // Group: sender(4) + slot(1) + text (no explicit length)
            // Minimum: 5 bytes (sender + slot)
            if (plen < 5) {
                stats.early_drop_malformed_text++;
                log1("early-drop short group plen=%d < 5\n", plen);
                tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
                continue;
            }
        }

        // 6. Emit the validated frame.
        const payload = substr(tcpbuf, HEADER_BYTES, plen);
        tcpbuf = substr(tcpbuf, HEADER_BYTES + plen);
        stats.frames_in++;
        push(frames, { cmd: cmd, payload: payload });
    }
}

// ---------------------------------------------------------------------
// Decoder — DIRECT_MSG_RECV (0x07) and CHANNEL_MSG_RECV (0x08) only.
// =====================================================================
//
// CORRECTED per Mathison (2026-06-19):
//
// Direct Message (0x07) payload structure:
//   Off  Size  Field
//   0    4     sender node id      (uint32 LE)
//   4    4     recipient node id   (uint32 LE)
//   8    1     text length (n)
//   9    n     UTF-8 text bytes
//
// Group Message (0x08) payload structure:
//   Off  Size  Field
//   0    4     sender node id      (uint32 LE)
//   4    1     group slot index    (0-7, identifies which memory slot)
//   5    ?     text (no explicit length, rest of payload)
//
// Note: Group messages DON'T have an explicit text length byte like
// direct messages. Text is from byte 5 to end of payload.
//
// All length validation already happened in the accumulator, so this
// is straight unpack.

function decodeTextFrame(cmd, payload)
{
    if (cmd === CMD_DIRECT_MSG_RECV) {
        // Direct message: sender(4) + recipient(4) + text_len(1) + text
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
        
    } else if (cmd === CMD_CHANNEL_MSG_RECV) {
        // Group message: sender(4) + group_slot(1) + text
        const fromId = u32le(payload, 0);
        const groupSlot = ord(payload, 4);  // 0-7, identifies memory slot
        const text = cstr(substr(payload, 5));
        
        if (!length(text)) {
            log1("decode: empty group text from=%08x slot=%d\n", fromId, groupSlot);
            return null;
        }

        msgSeq = (msgSeq + 1) & 0xFFFFFFFF;
        const msg = {
            id:                   msgSeq,
            from:                 fromId,
            group_slot:           groupSlot,  // 0-7, for slot-based routing
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
    
    // Unknown frame type (shouldn't happen, smartAccumulate filters)
    log1("decode: unknown frame cmd=0x%02x\n", cmd);
    return null;
}

// ---------------------------------------------------------------------
// Public lifecycle API (mirrors meshtastic_API.uc)
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

    // --- Device name & channel creation ---
    // Inject our channel into config.channels so that channel.setup()
    // (which runs after us in config.uc) picks it up automatically.
    // This avoids timing issues with lazy tick-based creation.
    deviceName = cfg.device_name ?? null;
    if (deviceName) {
        channelNamekey = `${deviceName} og==`;
        // Build a friendly label combining local hostname, MeshCore device, and channel name.
        // Channel name defaults to "Public" until Phase-2 slot discovery lands.
        let hostname = "";
        try {
            const h = fs.readfile("/proc/sys/kernel/hostname");
            if (h) hostname = replace(h, "\n", "");
        } catch (e) {}
        const chanName = cfg.channel_name ?? "Public";
        const label = hostname
            ? `${hostname} \u00b7 ${deviceName} \u00b7 ${chanName}`
            : `${deviceName} \u00b7 ${chanName}`;
        if (!config.channels) config.channels = [];
        let found = false;
        for (let i = 0; i < length(config.channels); i++) {
            if (config.channels[i].namekey === channelNamekey) {
                config.channels[i].label = label;
                found = true;
                break;
            }
        }
        if (!found) {
            push(config.channels, { namekey: channelNamekey, label: label });
        }
        log0("channel registered: %s (label: %s)\n", channelNamekey, label);
    }
    channelCreated = true;

    // Cache a Strict-mode probe. We only need to know whether
    // strict-mode is on; the router runs the full gatekeeper pass
    // (filterInboundBridge) on every queued meshcore message, so we
    // don't double-filter here.
    const gk = config._gatekeeper;
    strictHook = gk && type(gk.isEnabled) === "function"
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
    // Drain any already-decoded messages first.
    if (length(pendingRx) > 0) return shift(pendingRx);

    // Reconnect path.
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
    // Outbound send is not yet implemented for the TCP Companion backend.
    // Production outbound continues via the existing meshcore.uc UDP path.
    log1("send: not implemented (msg.id=%s)\n", msg?.id);
    return false;
};

export function tick()
{
    // Lazy channel creation: after SELF_INFO (0x05) is received,
    // deviceName becomes available. Create the channel on first tick.
    if (enabled && deviceName && !channelCreated && channel) {
        createAutoChannel();
    }
};

// -----
// createAutoChannel() — Register MeshCore device as a channel
// =====================================================================
//
// Called lazily from tick() after SELF_INFO response is received
// and deviceName is captured. Follows the same pattern as APRS backend.
//
// Channel name format: "{device_name} og=="
// Example: "KJ6DZB-MLK og=="
//
// =====================================================================

function createAutoChannel()
{
    if (!deviceName) {
        log1("createAutoChannel: deviceName not set\n");
        return;
    }

    channelNamekey = `${deviceName} og==`;

    try {
        // Get all existing local channels
        const localChannels = channel.getAllLocalChannels();
        
        // Check if our channel already exists
        let hasChannel = false;
        for (let i = 0; i < length(localChannels); i++) {
            if (localChannels[i].namekey === channelNamekey) {
                hasChannel = true;
                break;
            }
        }
        
        // Add if not present
        if (!hasChannel) {
            push(localChannels, { namekey: channelNamekey });
            channel.updateLocalChannels(localChannels);
            rootConfig.update?.("channels");
            log0("auto-created channel: %s\n", channelNamekey);
        } else {
            log1("channel already exists: %s\n", channelNamekey);
        }
        
        channelCreated = true;
    }
    catch (err) {
        log0("createAutoChannel error: %s\n", err);
        stats.early_drop_unknown_cmd++;  // Count as error
    }
}

export function process(msg)
{
    // Message processing for TCP API backend.
    // Currently a stub; future enhancements could include:
    // - Outbound message routing
    // - Priority queue management
};

// ---------------------------------------------------------------------
// Test/introspection hooks (used by tests/test_meshcore_tcp_api.uc).
// These are side-door entry points so the buffer state machine can be
// exercised without a real socket.
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
    msgSeq = 0;
    for (let k in stats) stats[k] = 0;
};

export function _test_stats()
{
    return stats;
};

export function _test_build_frame(cmd, payload)
{
    return buildFrame(cmd, payload);
};
