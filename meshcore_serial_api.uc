// =====================================================================
// MeshCore USB Serial Companion backend
// =====================================================================
//
// Direct USB CDC serial implementation for a MeshCore Companion radio.
// ArduinoSerialInterface uses the same framing as the TCP Companion API:
//
//   Radio -> Crow: '>' + uint16le(length) + command/payload
//   Crow -> Radio: '<' + uint16le(length) + command/payload
//
// The backend intentionally exposes cleartext text only.  It supports
// CMD_APP_START, bounded queued-message draining (0x83 -> CMD 0x0a), and
// outbound *group* text.  Direct text needs a
// real MeshCore contact/path table, which Crow does not own yet, so it is
// explicitly rejected rather than guessing a recipient prefix.
//
// The AREDN socket.poll implementation can hang on a raw TTY file descriptor,
// so serial receive is drained by a short nonblocking timer rather than being
// registered with the socket poll loop. The device is opened as one
// bidirectional stream for this AREDN image; bounded one-byte reads and
// explicit flushes keep direction changes safe. After validating the only
// supported USB CDC paths and 115200 baud, fixed serial setup is applied.
// Stripped-down AREDN images use Crow's bundled rawtty helper. The only
// interpolated value is the strict-whitelisted device path.

import * as fs from "fs";
import * as timers from "timers";
import * as channel from "channel";

const FRAME_FROM_RADIO         = 0x3e; // '>'
const FRAME_TO_RADIO           = 0x3c; // '<'
const HEADER_BYTES             = 3;
const SERIAL_READ_CHUNK        = 2048;
const SMART_MAX_PAYLOAD        = 256;
const RESYNC_BUFFER_CAP        = 4096;
const REOPEN_INTERVAL          = 5;
const SERIAL_POLL_INTERVAL     = 1;
const SERIAL_STARTUP_SETTLE    = 2;
const SERIAL_HANDSHAKE_RETRY   = 5;
const SERIAL_HANDSHAKE_ATTEMPTS = 3;
const DEFAULT_QUEUE_POLL       = 5;
const DEFAULT_MAX_PENDING_RX   = 4;
const HARD_MAX_PENDING_RX      = 32;
const MAX_CHANNEL_INDEX        = 7;
const MAX_GROUP_TEXT_LENGTH    = 160;
const RAWTTY_HELPER            = "/usr/local/crow/crow-rawtty";
const DISCOVERY_NOTICE_INTERVAL = 300;

const CMD_APP_START            = 0x01;
const CMD_SEND_CHANNEL_TXT_MSG = 0x03;
const CMD_SYNC_NEXT_MESSAGE    = 0x0a;

const RESP_OK                  = 0x00;
const RESP_ERR                 = 0x01;
const RESP_SELF_INFO           = 0x05;
const RESP_DIRECT_MSG_RECV     = 0x07;
const RESP_CHANNEL_MSG_RECV    = 0x08;
const RESP_NO_MORE_MESSAGES    = 0x0a;
const RESP_DIRECT_MSG_RECV_V3  = 0x10;
const RESP_CHANNEL_MSG_RECV_V3 = 0x11;
const RESP_CHANNEL_INFO        = 0x12;
const RESP_CHANNEL_DATA_RECV   = 0x1b;
const PUSH_SEND_CONFIRMED      = 0x82;
const PUSH_MSG_WAITING         = 0x83;
const PUSH_NEW_ADVERT           = 0x8a;
const PUSH_CONTACTS_FULL        = 0x90;
const CMD_ENCRYPTED_DM         = 0x90;
const CMD_ENCRYPTED_BIN        = 0x91;

const TXT_TYPE_PLAIN           = 0x00;
const MAX_CHANNEL_DATA_LENGTH  = 163;

const PART97_BLOCKED_COMMANDS = {
    [CMD_ENCRYPTED_DM]: true,
    [CMD_ENCRYPTED_BIN]: true
};

let cfg = null;
let rootConfig = null;
export let enabled = false;
let serialRx = null;
let serialTx = null;
let serialDevice = "/dev/ttyACM0";
let serialBaud = 115200;
let serialState = "not-configured";
let nextOpenTime = 0;
let handshakeDue = 0;
let handshakeAttempts = 0;
let companionReady = false;
let lastError = null;
let framebuf = "";
let pendingSkip = 0;
let pendingRx = [];
let deferredFrames = [];
let responses = [];
let discoveredChannels = {};
let syncingMessages = false;
let syncRequestInFlight = false;
let syncPausedBackpressure = false;
let queuePollSeconds = DEFAULT_QUEUE_POLL;
let nextQueuePollTime = 0;
let configuredChannelNamekey = null;
let outboundChannelIndex = 0;
let strictHook = null;
let strictDirectIdentity = false;
let channelDataTextTypes = {};
let callsign = null;
let deviceName = null;
let msgSeq = 0;
let lastRxTime = null;
let lastCmd = null;
let lastDiscoveryNotice = 0;

let stats = {
    opens: 0,
    closes: 0,
    handshakes_sent: 0,
    bytes_rx: 0,
    bytes_tx: 0,
    frames_in: 0,
    frames_decoded: 0,
    commands_sent: 0,
    self_info: 0,
    message_waiting: 0,
    no_more_messages: 0,
    sync_requests: 0,
    sync_backpressure: 0,
    responses_cached: 0,
    direct_identity_unverified: 0,
    direct_identity_dropped: 0,
    group_receive_unverified: 0,
    channel_data_received: 0,
    channel_data_routed: 0,
    channel_data_unrouted: 0,
    outbound_group_sent: 0,
    outbound_group_rejected: 0,
    outbound_confirmed: 0,
    radio_errors: 0,
    early_drop_oversize: 0,
    early_drop_encrypted: 0,
    early_drop_unknown_cmd: 0,
    early_drop_malformed_text: 0,
    early_drop_queue_full: 0,
    resync_skips: 0
};

function log0(fmt, ...args)
{
    DEBUG0("meshcore_serial_api: " + fmt, ...args);
}

function log1(fmt, ...args)
{
    DEBUG1("meshcore_serial_api: " + fmt, ...args);
}

function notifyIgnoredDiscovery(kind)
{
    const now = time();
    if (lastDiscoveryNotice && now - lastDiscoveryNotice < DISCOVERY_NOTICE_INTERVAL) {
        return;
    }
    lastDiscoveryNotice = now;
    try {
        global.event?.queue?.({ cmd: "/reply", reply: [
            "<b>MeshCore discovery ignored</b>",
            `${kind} discovery is not retained by Crow.`,
            "Only direct messages and configured group-channel messages are kept."
        ] });
        global.event?.notify?.({ cmd: "channels" }, "meshcore-discovery-ignored");
    }
    catch (_) {}
}

function isDirectFrame(cmd)
{
    return cmd === RESP_DIRECT_MSG_RECV || cmd === RESP_DIRECT_MSG_RECV_V3;
}

function isGroupFrame(cmd)
{
    return cmd === RESP_CHANNEL_MSG_RECV || cmd === RESP_CHANNEL_MSG_RECV_V3;
}

function incomingPrefixBytes(cmd)
{
    // Protocol v3 prepends SNR (signed quarter-dB) and two reserved bytes to
    // every queued text record.  Earlier protocol versions have no prefix.
    return (cmd === RESP_DIRECT_MSG_RECV_V3 || cmd === RESP_CHANNEL_MSG_RECV_V3) ? 3 : 0;
}

function le16(buf, off)
{
    return (ord(buf, off) & 0xff) | ((ord(buf, off + 1) << 8) & 0xff00);
}

function packLe16(n)
{
    return chr(n & 0xff) + chr((n >> 8) & 0xff);
}

function packLe32(n)
{
    return chr(n & 0xff) + chr((n >> 8) & 0xff) +
        chr((n >> 16) & 0xff) + chr((n >> 24) & 0xff);
}

function u32le(buf, off)
{
    return (ord(buf, off) |
        (ord(buf, off + 1) << 8) |
        (ord(buf, off + 2) << 16) |
        (ord(buf, off + 3) << 24)) & 0xffffffff;
}

function cstr(value)
{
    if (!value) return "";
    let n = length(value);
    while (n > 0 && ord(value, n - 1) === 0) n--;
    return substr(value, 0, n);
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

function validDevicePath(device)
{
    // CDC ACM is expected for the RAK3401 Companion USB device; USB serial
    // adapters are allowed too.  This rejects shell metacharacters and other
    // arbitrary files before the fixed-argv serial setup or fs.open().
    return type(device) === "string" &&
        // ucode's target regex engine does not support non-capturing groups.
        // Keep the two exact alternatives rather than weakening validation.
        (match(device, /^\/dev\/ttyACM[0-9]+$/) !== null ||
            match(device, /^\/dev\/ttyUSB[0-9]+$/) !== null);
}

function channelDataTextTypeEnabled(dataType)
{
    return channelDataTextTypes[`${dataType}`] === true;
}

function validChannelDataPayload(payload)
{
    if (!payload || length(payload) < 9) return false;
    const index = ord(payload, 3);
    const dataLen = ord(payload, 7);
    return index <= 7 && dataLen <= MAX_CHANNEL_DATA_LENGTH &&
        8 + dataLen <= length(payload);
}

function isMostlyPrintable(value)
{
    if (!value || length(value) === 0) return false;
    let printable = 0;
    for (let i = 0; i < length(value); i++) {
        const byte = ord(value, i);
        if (byte === 9 || byte === 10 || byte === 13 ||
            (byte >= 0x20 && byte <= 0x7e) || byte >= 0x80) {
            printable++;
        }
    }
    return printable >= length(value) * 0.75;
}

function resetWireState()
{
    framebuf = "";
    pendingSkip = 0;
    syncingMessages = false;
    syncRequestInFlight = false;
    syncPausedBackpressure = false;
    nextQueuePollTime = time() + queuePollSeconds;
    handshakeDue = 0;
    handshakeAttempts = 0;
    companionReady = false;
}

function closeSerial(reason)
{
    const wasOpen = serialRx || serialTx;
    if (serialRx) {
        try { serialRx.close(); } catch (_) {}
    }
    if (serialTx && serialTx !== serialRx) {
        try { serialTx.close(); } catch (_) {}
    }
    serialRx = null;
    serialTx = null;
    resetWireState();
    if (wasOpen) {
        stats.closes++;
        log0("serial closed (%s)\n", reason ?? "unknown");
    }
    if (enabled) {
        serialState = "reconnecting";
        nextOpenTime = time() + REOPEN_INTERVAL;
    }
}

function runSerialSetup(command, label)
{
    let p = null;
    try {
        // The AREDN ucode runtime accepts only a command string here (not an
        // argv array).  `serialDevice` was strictly constrained by
        // validDevicePath() before this function can be reached, and every
        // other token is an internal literal.
        p = fs.popen(command, "r");
        if (!p) {
            lastError = fs.error() ?? `unable to start ${label}`;
            return false;
        }
        // Consume stderr-less output and wait for command completion.  A
        // nonzero close status is treated as a configuration failure.
        p.read("all");
        const result = p.close();
        if (result !== 0) {
            lastError = `${label} exit ${result}`;
            return false;
        }
        return true;
    }
    catch (e) {
        try { p?.close(); } catch (_) {}
        lastError = `${e}`;
        return false;
    }
}

function configureSerialPort()
{
    // Keep the physical serial setup deterministic. The device value is the
    // exact `/dev/ttyACM<N>` or `/dev/ttyUSB<N>` path already validated by
    // openSerial(); the baud literal is intentionally fixed at 115200.
    if (fs.access("/bin/stty")) {
        return runSerialSetup(
            `/bin/stty -F ${serialDevice} 115200 raw -echo cs8 -cstopb -parenb -ixon -ixoff min 0 time 0`,
            "stty");
    }

    // AREDN's minimal busybox image omits stty. The bundled static helper
    // applies termios directly with ioctl and exits without restoring it.
    // Crow remains the sole owner of the radio's read/write handles.
    if (fs.access(RAWTTY_HELPER)) {
        return runSerialSetup(
            `${RAWTTY_HELPER} ${serialDevice}`,
            "bundled rawtty setup");
    }

    lastError = "neither /bin/stty nor bundled crow-rawtty is available for serial setup";
    return false;
}

function openSerial()
{
    if (!validDevicePath(serialDevice)) {
        serialState = "invalid-device";
        lastError = "device must be /dev/ttyACM<N> or /dev/ttyUSB<N>";
        log0("%s\n", lastError);
        return false;
    }
    if (serialBaud !== 115200) {
        serialState = "unsupported-baud";
        lastError = "only 115200 baud is supported by the USB Companion backend";
        log0("%s\n", lastError);
        return false;
    }
    // Open the device only after confirming it is a character device.  In
    // particular, fs.open(path, "w") can create a plain file when a USB ACM
    // device has re-enumerated under a different number.
    const deviceStat = fs.stat(serialDevice);
    if (!deviceStat || deviceStat.type !== "char") {
        serialState = "missing-device";
        lastError = "device path is not a character device";
        nextOpenTime = time() + REOPEN_INTERVAL;
        log0("%s: %s\n", lastError, serialDevice);
        return false;
    }
    try {
        // AREDN's fs.open() exposes the tty as a stdio-backed handle. Use one
        // read/write stream here: on this image separately opened read/write
        // streams can leave the Companion response on the other tty state.
        // Keep socket.poll() out of this path and use explicit one-byte reads
        // below, so each timer tick remains bounded.
        const serial = fs.open(serialDevice, "r+");
        if (!serial) {
            try { serial?.close(); } catch (_) {}
            lastError = fs.error() ?? "open failed";
            serialState = "open-failed";
            nextOpenTime = time() + REOPEN_INTERVAL;
            return false;
        }
        serialRx = serial;
        serialTx = serial;
        // Configure after the descriptors are open. USB CDC implementations
        // may restore tty defaults when the last descriptor closes, which
        // makes a setup helper run before fs.open() ineffective.
        if (!configureSerialPort()) {
            closeSerial("configure failed");
            serialState = "configure-failed";
            log0("unable to configure %s: %s\n", serialDevice, lastError ?? "unknown error");
            nextOpenTime = time() + REOPEN_INTERVAL;
            return false;
        }
        serialState = "connecting";
        lastError = null;
        stats.opens++;
        // Opening a RAK CDC ACM port can reset the companion firmware.  Sending
        // APP_START immediately races that reset and loses the entire reply.
        // Keep the handles open, allow the USB device to settle, then send the
        // first command from tick().
        handshakeDue = time() + SERIAL_STARTUP_SETTLE;
        log0("opened USB Companion serial %s at 115200; handshake in %d seconds\n",
            serialDevice, SERIAL_STARTUP_SETTLE);
        return true;
    }
    catch (e) {
        lastError = `${e}`;
        serialState = "open-failed";
        nextOpenTime = time() + REOPEN_INTERVAL;
        return false;
    }
}

function buildRadioFrame(cmd, payload)
{
    payload = payload ?? "";
    const body = chr(cmd & 0xff) + payload;
    return chr(FRAME_FROM_RADIO) + packLe16(length(body)) + body;
}

function buildCommand(cmd, payload)
{
    payload = payload ?? "";
    const body = chr(cmd & 0xff) + payload;
    return chr(FRAME_TO_RADIO) + packLe16(length(body)) + body;
}

function writeFrame(frame, label)
{
    if (!serialTx) return false;
    try {
        const written = serialTx.write(frame);
        if (written !== length(frame)) {
            lastError = fs.error() ?? `short write ${written}/${length(frame)}`;
            closeSerial(`${label ?? "frame"} short write`);
            return false;
        }
        if (!serialTx.flush()) {
            lastError = fs.error() ?? "flush failed";
            closeSerial(`${label ?? "frame"} flush failed`);
            return false;
        }
        stats.bytes_tx += written;
        return true;
    }
    catch (e) {
        lastError = `${e}`;
        closeSerial(`${label ?? "frame"} write failed`);
        return false;
    }
}

export function sendCommand(cmd, payload)
{
    const frame = buildCommand(cmd, payload ?? "");
    if (!writeFrame(frame, sprintf("command 0x%02x", cmd))) {
        return false;
    }
    stats.commands_sent++;
    log1("sent command 0x%02x (%d bytes)\n", cmd, length(frame));
    return true;
};

function appStartPayload()
{
    // Firmware ignores the seven reserved bytes.  Retain the meshcore-cli
    // profile for radios tested by the original probe, with a safe zeros
    // fallback for simple Companion builds.
    if (cfg?.app_start_profile === "crow_zeros") {
        return "\x00\x00\x00\x00\x00\x00\x00Crow";
    }
    return "\x03\x20\x20\x20\x20\x20\x20Crow";
}

function sendBootHandshake()
{
    if (!serialTx) return false;
    const ok = sendCommand(CMD_APP_START, appStartPayload());
    if (ok) {
        stats.handshakes_sent++;
        handshakeAttempts++;
        handshakeDue = time() + SERIAL_HANDSHAKE_RETRY;
        log0("handshake sent (CMD_APP_START); waiting for self-info/queue push\n");
        // Wait for self-info or a queue push before issuing 0x0a. Some
        // Companion builds treat an immediate sync request as a pre-handshake
        // command and then never return self-info to the host.
    }
    return ok;
}

function pauseSyncForBackpressure(reason)
{
    if (!syncPausedBackpressure) {
        log1("sync backpressure: pending_rx=%d max=%d (%s)\n",
            length(pendingRx), maxPendingRx(), reason ?? "unknown");
    }
    syncPausedBackpressure = true;
    stats.sync_backpressure++;
}

function sendSyncNextMessage(reason)
{
    if (!serialTx || syncRequestInFlight) return false;
    if (pendingFull()) {
        syncingMessages = true;
        pauseSyncForBackpressure(reason);
        return false;
    }
    syncingMessages = true;
    syncRequestInFlight = true;
    syncPausedBackpressure = false;
    stats.sync_requests++;
    if (!sendCommand(CMD_SYNC_NEXT_MESSAGE, "")) {
        syncRequestInFlight = false;
        return false;
    }
    return true;
}

function maybeRequestNext(reason)
{
    if (!syncingMessages || syncRequestInFlight || !serialTx) return false;
    return sendSyncNextMessage(reason);
}

function parseSelfInfo(framePayload)
{
    if (!framePayload || length(framePayload) < 36 || ord(framePayload, 0) !== RESP_SELF_INFO) {
        return null;
    }
    // Self info has variable firmware metadata after the public key and a
    // trailing node name. Scan backward from the tail so binary public-key or
    // metadata bytes that happen to look printable cannot become the name.
    let end = length(framePayload);
    while (end > 0 && ord(framePayload, end - 1) === 0) end--;
    let start = end;
    while (start > 0) {
        const byte = ord(framePayload, start - 1);
        if (byte < 0x20 || byte > 0x7e) break;
        start--;
    }
    return start < end ? substr(framePayload, start, end - start) : null;
}

function mapConfiguredChannels()
{
    // channel.setup() runs after meshcore.setup(), so map on each tick once
    // Crow's configured channel table is available. Slots are explicitly
    // configured; radio discovery is intentionally not retained.
    for (let index in discoveredChannels) {
        const found = discoveredChannels[index];
        const local = channel.getLocalChannelByNameKey(found.namekey);
        const mapped = channel.getChannelByMeshcoreSlot(found.index);
        if (local) {
            channel.setMeshcoreSlotChannel(found.index, local);
        }
        else if (mapped) {
            // The local channel may have been removed or its key changed.
            // Remove stale receive authority immediately.
            channel.clearMeshcoreSlotChannel(found.index);
        }
    }
}

function registerConfiguredChannelSlots(config)
{
    const register = function (slot, namekey) {
        slot = int(slot);
        if (slot < 0 || slot > MAX_CHANNEL_INDEX || !namekey) return;
        const parts = split(namekey, " ");
        if (length(parts) !== 2) return;
        discoveredChannels[`${slot}`] = {
            index: slot,
            name: parts[0],
            secret_b64: parts[1],
            namekey: namekey,
            configured: true
        };
    };

    register(outboundChannelIndex, configuredChannelNamekey);
    const slots = cfg?.channel_slots;
    if (type(slots) === "array") {
        for (let i = 0; i < length(slots); i++) {
            register(slots[i]?.slot, slots[i]?.namekey);
        }
    }
    else if (slots && type(slots) === "object") {
        for (let slot in slots) register(slot, slots[slot]);
    }
    const channels = config?.channels ?? [];
    for (let i = 0; i < length(channels); i++) {
        if (channels[i]?.meshcore_slot != null) {
            register(channels[i].meshcore_slot, channels[i].namekey);
        }
    }
    mapConfiguredChannels();
}

function verifiedLocalChannelForSlot(slot, namekey)
{
    if (slot === null || slot < 0 || slot > MAX_CHANNEL_INDEX || !namekey) {
        return null;
    }
    const discovered = discoveredChannels[`${slot}`];
    if (!discovered || discovered.namekey !== namekey) {
        return null;
    }
    const local = channel.getLocalChannelByNameKey(namekey);
    const mapped = channel.getChannelByMeshcoreSlot(slot);
    if (!local || !mapped || mapped.namekey !== namekey) {
        return null;
    }
    return local;
}

function parseChannelData(payload)
{
    // Companion 0x1b receive payload:
    // [snr][reserved:2][slot][path_len][data_type:2 LE][data_len][data].
    if (!validChannelDataPayload(payload)) return null;
    const rawSnr = ord(payload, 0);
    const snr = (rawSnr > 127 ? rawSnr - 256 : rawSnr) / 4.0;
    const slot = ord(payload, 3);
    const pathLen = ord(payload, 4);
    const dataType = le16(payload, 5);
    const dataLen = ord(payload, 7);
    stats.channel_data_received++;
    if (!channelDataTextTypeEnabled(dataType)) {
        stats.channel_data_unrouted++;
        log1("drop channel datagram type=0x%04x slot=%d len=%d (type not enabled)\n",
            dataType, slot, dataLen);
        return null;
    }

    const text = cstr(substr(payload, 8, dataLen));
    if (!isMostlyPrintable(text)) {
        stats.channel_data_unrouted++;
        log1("drop channel datagram type=0x%04x slot=%d (not printable text)\n",
            dataType, slot);
        return null;
    }
    const mapped = channel.getChannelByMeshcoreSlot(slot);
    if (!mapped || !verifiedLocalChannelForSlot(slot, mapped.namekey)) {
        stats.channel_data_unrouted++;
        stats.group_receive_unverified++;
        log1("drop channel datagram slot=%d until radio/Crow channel namekey matches\n", slot);
        return null;
    }

    msgSeq = (msgSeq + 1) & 0xffffffff;
    stats.channel_data_routed++;
    return {
        id: msgSeq,
        group_slot: slot,
        channel_index: slot,
        namekey: mapped.namekey,
        rx_time: time(),
        hop_limit: 1,
        transport: "meshcore",
        backend: "serial_api",
        originating_callsign: callsign,
        data: { text_message: text },
        metadata: {
            is_group_message: true,
            group_slot: slot,
            channel_index: slot,
            text_type: TXT_TYPE_PLAIN,
            path_length: pathLen,
            rx_snr: snr,
            identity_strength: "weak",
            symmetric_key: true,
            requires_slot_lookup: true,
            channel_data: true,
            channel_data_type: dataType
        }
    };
}

function advanceOversize(payloadBytes)
{
    const total = HEADER_BYTES + payloadBytes;
    if (length(framebuf) >= total) {
        framebuf = substr(framebuf, total);
        return;
    }
    pendingSkip = total - length(framebuf);
    framebuf = "";
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
    if (data && length(data) > 0) framebuf += data;

    const strictOn = strictHook ? strictHook() : false;
    for (;;) {
        const blen = length(framebuf);
        if (blen === 0) return frames;
        if (ord(framebuf, 0) !== FRAME_FROM_RADIO) {
            let start = -1;
            for (let i = 1; i < blen; i++) {
                if (ord(framebuf, i) === FRAME_FROM_RADIO) { start = i; break; }
            }
            if (start < 0) {
                if (blen > RESYNC_BUFFER_CAP) {
                    stats.resync_skips++;
                    framebuf = "";
                }
                return frames;
            }
            stats.resync_skips++;
            framebuf = substr(framebuf, start);
            continue;
        }
        if (blen < HEADER_BYTES) return frames;

        const plen = le16(framebuf, 1);
        if (plen < 1) {
            stats.early_drop_malformed_text++;
            framebuf = substr(framebuf, HEADER_BYTES);
            continue;
        }
        if (plen > SMART_MAX_PAYLOAD) {
            stats.early_drop_oversize++;
            advanceOversize(plen);
            continue;
        }
        if (blen < HEADER_BYTES + plen) return frames;

        const framePayload = substr(framebuf, HEADER_BYTES, plen);
        framebuf = substr(framebuf, HEADER_BYTES + plen);
        const cmd = ord(framePayload, 0);
        const payload = substr(framePayload, 1);
        const dataLen = plen - 1;
        stats.frames_in++;
        lastCmd = cmd;

        if (cmd === PUSH_MSG_WAITING) {
            stats.message_waiting++;
            companionReady = true;
            handshakeDue = 0;
            handshakeAttempts = 0;
            syncingMessages = true;
            maybeRequestNext("push 0x83");
            continue;
        }
        if (cmd === RESP_NO_MORE_MESSAGES) {
            stats.no_more_messages++;
            syncingMessages = false;
            syncRequestInFlight = false;
            syncPausedBackpressure = false;
            nextQueuePollTime = time() + queuePollSeconds;
            continue;
        }
        if (cmd === PUSH_SEND_CONFIRMED || cmd === RESP_OK) {
            stats.outbound_confirmed++;
            continue;
        }
        if (cmd === RESP_ERR) {
            stats.radio_errors++;
            log0("radio rejected a Companion command (error=%s)\n",
                dataLen > 0 ? ord(payload, 0) : "unspecified");
            continue;
        }
        if (strictOn && PART97_BLOCKED_COMMANDS[cmd]) {
            stats.early_drop_encrypted++;
            syncRequestInFlight = false;
            maybeRequestNext("drop encrypted");
            continue;
        }
        if (cmd === RESP_SELF_INFO) {
            stats.self_info++;
            companionReady = true;
            serialState = "connected";
            handshakeDue = 0;
            handshakeAttempts = 0;
            syncRequestInFlight = false;
            syncingMessages = true;
            deviceName = parseSelfInfo(framePayload) ?? deviceName;
            if (deviceName) log0("connected Companion device: %s\n", deviceName);
            continue;
        }
if (cmd === RESP_CHANNEL_INFO) {
    syncRequestInFlight = false;
    notifyIgnoredDiscovery("Channel");
            if (companionReady) maybeRequestNext("drop channel discovery");
            continue;
        }
        if (cmd === RESP_CHANNEL_DATA_RECV) {
            syncRequestInFlight = false;
            if (validChannelDataPayload(payload)) {
                push(frames, { cmd: cmd, payload: payload });
            }
            else {
                stats.early_drop_malformed_text++;
                log1("drop malformed channel datagram len=%d\n", length(payload));
            }
            if (companionReady) maybeRequestNext("channel data");
            continue;
        }
        if (cmd === PUSH_NEW_ADVERT || cmd === PUSH_CONTACTS_FULL) {
            notifyIgnoredDiscovery("Contact");
            stats.early_drop_unknown_cmd++;
            syncRequestInFlight = false;
            if (companionReady) maybeRequestNext("drop contact discovery");
            continue;
        }
        if (!isDirectFrame(cmd) && !isGroupFrame(cmd)) {
            stats.early_drop_unknown_cmd++;
            syncRequestInFlight = false;
            if (companionReady) {
                maybeRequestNext("drop unknown");
            }
            continue;
        }

        syncRequestInFlight = false;
        if (isDirectFrame(cmd)) {
            // Contact message: [v3 prefix?][pubkey-prefix:6][path:1]
            // [text-type:1][timestamp:4][plain text].  Do not pretend a
            // six-byte public-key prefix is a from/to uint32 envelope.
            const off = incomingPrefixBytes(cmd);
            if (dataLen < off + 12 || ord(payload, off + 7) !== TXT_TYPE_PLAIN) {
                stats.early_drop_malformed_text++;
                maybeRequestNext("drop malformed direct");
                continue;
            }
        }
        else {
            // Channel message: [v3 prefix?][channel-slot:1][path:1]
            // [text-type:1][timestamp:4][plain text].  Old code incorrectly
            // decoded this as a sender uint32 followed by slot/text.
            const off = incomingPrefixBytes(cmd);
            if (dataLen < off + 7 || ord(payload, off) > MAX_CHANNEL_INDEX ||
                ord(payload, off + 2) !== TXT_TYPE_PLAIN) {
                stats.early_drop_malformed_text++;
                maybeRequestNext("drop malformed group");
                continue;
            }
        }
        push(frames, { cmd: cmd, payload: payload });
    }
}

function decodeTextFrame(cmd, payload)
{
    if (cmd === RESP_CHANNEL_DATA_RECV) {
        if (!validChannelDataPayload(payload)) {
            stats.early_drop_malformed_text++;
            return null;
        }
        return parseChannelData(payload);
    }
    if (isDirectFrame(cmd)) {
        const off = incomingPrefixBytes(cmd);
        const text = cstr(substr(payload, off + 12));
        if (!text) return null;
        stats.direct_identity_unverified++;
        if (strictDirectIdentity) {
            stats.direct_identity_dropped++;
            log1("drop modern direct frame: destination identity unavailable\n");
            return null;
        }
        msgSeq = (msgSeq + 1) & 0xffffffff;
        return {
            id: msgSeq,
            // Crow has a numeric node-id field while Companion exposes a
            // six-byte contact public-key prefix.  Preserve both without
            // fabricating a destination ID from header bytes.
            from: hexenc(substr(payload, off, 6)),
            from_key_prefix: substr(payload, off, 6),
            sender_timestamp: u32le(payload, off + 8),
            rx_time: time(),
            hop_limit: 1,
            transport: "meshcore",
            backend: "serial_api",
            originating_callsign: callsign,
            data: { text_message: text },
            metadata: {
                is_group_message: false,
                identity_strength: "prefix",
                local_direct: true,
                direct_identity_verified: false
            }
        };
    }
    if (isGroupFrame(cmd)) {
        const off = incomingPrefixBytes(cmd);
        const text = cstr(substr(payload, off + 7));
        if (!text) return null;
        const slot = ord(payload, off);
        const mapped = channel.getChannelByMeshcoreSlot(slot);
        if (!mapped || !verifiedLocalChannelForSlot(slot, mapped.namekey)) {
            stats.group_receive_unverified++;
            log1("drop MeshCore group slot=%d until radio/Crow channel namekey matches\n", slot);
            return null;
        }
        msgSeq = (msgSeq + 1) & 0xffffffff;
        return {
            id: msgSeq,
            group_slot: slot,
            namekey: mapped.namekey,
            sender_timestamp: u32le(payload, off + 3),
            rx_time: time(),
            hop_limit: 1,
            transport: "meshcore",
            backend: "serial_api",
            originating_callsign: callsign,
            data: { text_message: text },
            metadata: {
                is_group_message: true,
                group_slot: slot,
                identity_strength: "weak",
                symmetric_key: true,
                requires_slot_lookup: true
            }
        };
    }
    return null;
}

function popPending(reason)
{
    if (length(pendingRx) === 0) return null;
    const msg = shift(pendingRx);
    maybeRequestNext(reason ?? "pending delivered");
    return msg;
}

function deferFrames(frames)
{
    for (let i = 0; i < length(frames); i++) {
        // A serial read can contain more than one valid frame.  Retain only
        // the configured pending budget, instead of turning one POLLIN event
        // into an unbounded decoded-message allocation.
        if (length(deferredFrames) + length(pendingRx) >= maxPendingRx()) {
            stats.early_drop_queue_full++;
            log1("drop decoded serial frame: pending budget full (%d)\n", maxPendingRx());
            continue;
        }
        push(deferredFrames, frames[i]);
    }
}

function promoteDeferredFrames()
{
    while (!pendingFull() && length(deferredFrames) > 0) {
        const frame = shift(deferredFrames);
        const msg = decodeTextFrame(frame.cmd, frame.payload);
        if (msg) {
            stats.frames_decoded++;
            push(pendingRx, msg);
        }
    }
}

function buildGroupTextCommand(msg, slot)
{
    const text = msg?.data?.text_message;
    if (type(text) !== "string" || length(text) === 0 || slot < 0 || slot > MAX_CHANNEL_INDEX) {
        return null;
    }
    const safeText = length(text) > MAX_GROUP_TEXT_LENGTH
        ? substr(text, 0, MAX_GROUP_TEXT_LENGTH) : text;
    const timestamp = msg?.rx_time ?? time();
    return buildCommand(CMD_SEND_CHANNEL_TXT_MSG,
        chr(TXT_TYPE_PLAIN) + chr(slot) + packLe32(timestamp) + safeText);
}

export function setup(config)
{
    // meshcore_backend historically called setup once for status and once for
    // activation.  Make the real resource lifecycle idempotent.
    closeSerial("reconfigure");
    cfg = config?.meshcore_serial_api ?? {};
    rootConfig = config;
    enabled = false;
    serialDevice = cfg.device ?? "/dev/ttyACM0";
    serialBaud = cfg.baud ?? 115200;
    serialState = cfg.enabled === true ? "opening" : "not-configured";
    // Serial mode uses explicit Crow channel-to-radio slot mappings. The
    // optional TCP discovery module is intentionally not part of this backend.
    strictDirectIdentity = cfg.strict_direct_identity === true || cfg.direct_identity_mode === "verified";
    channelDataTextTypes = {};
    const textTypes = cfg.channel_data_text_types;
    if (textTypes && type(textTypes) === "array") {
        for (let i = 0; i < length(textTypes); i++) {
            const dataType = int(textTypes[i]);
            if (dataType >= 1 && dataType <= 0xffff) {
                channelDataTextTypes[`${dataType}`] = true;
            }
        }
    }
    queuePollSeconds = cfg.queue_poll_seconds ?? DEFAULT_QUEUE_POLL;
    if (queuePollSeconds < 1) queuePollSeconds = 1;
    if (queuePollSeconds > 60) queuePollSeconds = 60;
    // The standard MeshCore public channel is the only safe implicit TX
    // target. Custom channels still require an explicit channel_namekey;
    // verifiedLocalChannelForSlot() continues to require the exact radio
    // discovery tuple before any send is allowed.
    configuredChannelNamekey = cfg.channel_namekey ?? channel.meshcorePublicChannelNamekey();
    outboundChannelIndex = cfg.tx_channel_index ?? cfg.channel_index ?? 0;
    if (outboundChannelIndex < 0 || outboundChannelIndex > MAX_CHANNEL_INDEX) {
        log0("invalid tx_channel_index=%s; using slot 0\n", outboundChannelIndex);
        outboundChannelIndex = 0;
    }
    registerConfiguredChannelSlots(config);
    callsign = config?.callsign ?? null;
    deviceName = cfg.device_name ?? null;
    const gk = config?._gatekeeper;
    strictHook = gk && type(gk.isEnabled) === "function"
        ? function () { return gk.isEnabled() === true; } : null;

    // Physical ArduinoSerialInterface is always framed.  Do not send a raw
// stream to a Companion radio; it would be ignored and look like a send.
    if (cfg.enabled !== true) return;
    if (cfg.frame_mode && cfg.frame_mode !== "framed" && cfg.frame_mode !== "auto") {
        serialState = "unsupported-frame-mode";
        lastError = "direct USB Companion requires framed mode";
        log0("%s\n", lastError);
        return;
    }
    enabled = true;
    nextOpenTime = 0;
    openSerial();
    timers.setInterval("meshcore_serial_api.poll", SERIAL_POLL_INTERVAL);
};

export function shutdown()
{
    enabled = false;
    timers.cancel("meshcore_serial_api.poll");
    closeSerial("shutdown");
    serialState = "stopped";
};

export function handle()
{
    // Do not pass a fs.file TTY to socket.poll(): on AREDN 4.26 it can block
    // indefinitely even with a finite timeout. tick() drains it instead.
    return null;
};

function readSerial()
{
    if (!serialRx) return null;
    try {
        // ucode's buffered file reader may wait for the requested size even
        // when the underlying tty has VMIN=0. Read one byte at a time and
        // stop on the first empty result; the hard bound keeps one timer tick
        // from allocating or processing an unbounded CDC burst.
        let data = "";
        for (let i = 0; i < SERIAL_READ_CHUNK; i++) {
            const byte = serialRx.read(1);
            if (byte === null) {
                lastError = fs.error() ?? "serial read failed";
                closeSerial("read failed");
                return null;
            }
            if (length(byte) === 0) break;
            data += byte;
        }
        if (length(data) > 0) {
            stats.bytes_rx += length(data);
            lastRxTime = time();
        }
        return data;
    }
    catch (e) {
        lastError = `${e}`;
        closeSerial("read exception");
        return null;
    }
}

function pumpSerial(reason)
{
    const data = readSerial();
    if (data === null || length(data) === 0) return false;
    const frames = smartAccumulate(data);
    deferFrames(frames);
    promoteDeferredFrames();
    maybeRequestNext(reason ?? "serial timer");
    return true;
}

export function recv()
{
    const queued = popPending("pending delivered");
    if (queued) return queued;

    promoteDeferredFrames();
    const deferred = popPending("deferred message delivered");
    if (deferred) return deferred;

    if (!pumpSerial("router receive")) return null;
    const msg = popPending("message delivered");
    if (msg) return msg;
    return null;
};

export function send(msg)
{
    // Group-only is intentional: direct Companion sends need the six-byte
    // contact public-key prefix and a valid radio-owned path/contact record.
    if (!configuredChannelNamekey || !msg?.namekey || channel.isDirect(msg.namekey) ||
        msg.namekey !== configuredChannelNamekey ||
        !verifiedLocalChannelForSlot(outboundChannelIndex, configuredChannelNamekey)) {
        stats.outbound_group_rejected++;
        log1("reject outbound message id=%s (unverified radio/Crow channel tuple)\n", msg?.id);
        return false;
    }
    const frame = buildGroupTextCommand(msg, outboundChannelIndex);
    if (!frame || !serialTx) {
        stats.outbound_group_rejected++;
        log1("reject outbound message id=%s (no frame or serial offline)\n", msg?.id);
        return false;
    }
    if (!writeFrame(frame, "group send")) {
        return false;
    }
    stats.commands_sent++;
    stats.outbound_group_sent++;
    log0("sent group text id=%s slot=%d bytes=%d\n", msg?.id, outboundChannelIndex, length(frame));
    return true;
};

export function tick()
{
    if (!enabled) return;
    mapConfiguredChannels();
    if (!serialRx && time() >= nextOpenTime) {
        nextOpenTime = time() + REOPEN_INTERVAL;
        openSerial();
    }
    if (serialTx && !companionReady && handshakeDue > 0 && time() >= handshakeDue) {
        if (handshakeAttempts >= SERIAL_HANDSHAKE_ATTEMPTS) {
            log0("Companion handshake timed out after %d attempts\n", handshakeAttempts);
            closeSerial("handshake timeout");
        }
        else {
            sendBootHandshake();
        }
    }
    if (serialRx && timers.tick("meshcore_serial_api.poll")) {
        pumpSerial("serial timer");
    }
    if (serialTx && companionReady && syncingMessages && !syncRequestInFlight && !pendingFull()) {
        maybeRequestNext(syncPausedBackpressure ? "resume after backpressure" : "tick resume");
    }
    if (serialTx && companionReady && !syncRequestInFlight && !pendingFull() && time() >= nextQueuePollTime) {
        syncingMessages = true;
        maybeRequestNext("periodic queue poll");
    }
};

export function process(msg) {};

export function pending()
{
    return length(pendingRx) + length(deferredFrames);
};

export function takeResponse(cmd)
{
    for (let i = 0; i < length(responses); i++) {
        if (responses[i].cmd === cmd) {
            const response = responses[i];
            splice(responses, i, 1);
            return response;
        }
    }
    return null;
};

export function status()
{
    return {
        state: serialState,
        device: serialDevice,
        baud: serialBaud,
        frame_mode: "framed",
        app_start_profile: cfg?.app_start_profile ?? "meshcore_cli",
        channel_discovery: false,
        channel_discovery_requests: 0,
        channel_info_responses: 0,
        channels_discovered: 0,
        channels_updated: 0,
        configured_channel_namekey: configuredChannelNamekey,
        outbound_channel_index: outboundChannelIndex,
        pending_rx: length(pendingRx) + length(deferredFrames),
        delivery_pending: length(pendingRx),
        deferred_frames: length(deferredFrames),
        max_pending_rx: maxPendingRx(),
        queue_poll_seconds: queuePollSeconds,
        opens: stats.opens,
        closes: stats.closes,
        handshakes_sent: stats.handshakes_sent,
        handshake_attempts: handshakeAttempts,
        handshake_ready: companionReady,
        bytes_rx: stats.bytes_rx,
        bytes_tx: stats.bytes_tx,
        frames_in: stats.frames_in,
        frames_decoded: stats.frames_decoded,
        commands_sent: stats.commands_sent,
        self_info: stats.self_info,
        message_waiting: stats.message_waiting,
        no_more_messages: stats.no_more_messages,
        sync_requests: stats.sync_requests,
        sync_backpressure: stats.sync_backpressure,
        direct_identity_unverified: stats.direct_identity_unverified,
        direct_identity_dropped: stats.direct_identity_dropped,
        direct_identity_mode: strictDirectIdentity ? "verified" : "compatibility",
        group_receive_unverified: stats.group_receive_unverified,
        channel_data_received: stats.channel_data_received,
        channel_data_routed: stats.channel_data_routed,
        channel_data_unrouted: stats.channel_data_unrouted,
        channel_data_text_types: keys(channelDataTextTypes),
        outbound_group_sent: stats.outbound_group_sent,
        outbound_group_rejected: stats.outbound_group_rejected,
        outbound_confirmed: stats.outbound_confirmed,
        radio_errors: stats.radio_errors,
        last_rx_time: lastRxTime,
        last_cmd: lastCmd,
        last_error: lastError,
        device_name: deviceName,
        syncing_messages: syncingMessages,
        sync_request_in_flight: syncRequestInFlight,
        sync_paused_backpressure: syncPausedBackpressure
    };
};

// CROW_TEST_HOOKS_BEGIN
// Focused parser/framing hooks used by the canonical ucode tests.
export function _test_reset()
{
    resetWireState();
    pendingRx = [];
    deferredFrames = [];
    responses = [];
    discoveredChannels = {};
    channel.clearMeshcoreSlotChannels();
    channelDataTextTypes = {};
    strictDirectIdentity = false;
    msgSeq = 0;
    for (let key in stats) stats[key] = 0;
};

export function _test_inject(data, gatekeeperShim)
{
    if (gatekeeperShim !== null) {
        strictHook = function () { return gatekeeperShim.isEnabled() === true; };
    }
    return smartAccumulate(data);
};

export function _test_decode(cmd, payload)
{
    return decodeTextFrame(cmd, payload);
};

export function _test_set_channel_data_text_types(types)
{
    channelDataTextTypes = {};
    for (let i = 0; i < length(types ?? []); i++) {
        const dataType = int(types[i]);
        if (dataType >= 1 && dataType <= 0xffff) {
            channelDataTextTypes[`${dataType}`] = true;
        }
    }
};

export function _test_set_strict_direct_identity(enabledMode)
{
    strictDirectIdentity = enabledMode === true;
};

export function _test_build_frame(cmd, payload)
{
    return buildRadioFrame(cmd, payload);
};

export function _test_build_command(cmd, payload)
{
    return buildCommand(cmd, payload);
};

export function _test_build_group_send(msg, slot)
{
    return buildGroupTextCommand(msg, slot);
};

export function _test_app_start_payload()
{
    return appStartPayload();
};

export function _test_parse_self_info(payload)
{
    return parseSelfInfo(payload);
};

export function _test_set_local_channels(configs)
{
    return channel.setLocalChannels(configs ?? []);
};

export function _test_set_discovered_channel(index, namekey)
{
    const parts = split(namekey ?? "", " ");
    if (length(parts) !== 2 || index < 0 || index > MAX_CHANNEL_INDEX) return false;
    discoveredChannels[`${index}`] = {
        index: index,
        name: parts[0],
        secret_b64: parts[1],
        namekey: namekey
    };
    mapConfiguredChannels();
    return verifiedLocalChannelForSlot(index, namekey) !== null;
};

export function _test_set_configured_channel(index, namekey)
{
    return _test_set_discovered_channel(index, namekey);
};

export function _test_decode_channel_info(framePayload)
{
    return require("meshcore_tcp_discovery_loader").decodeChannelInfoForTest(framePayload);
};

export function _test_channel_receive_allowed(index, namekey)
{
    return verifiedLocalChannelForSlot(index, namekey) !== null;
};

export function _test_stats()
{
    return stats;
};
// CROW_TEST_HOOKS_END
