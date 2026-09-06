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
import * as channel from "channel";
import * as nodedb from "nodedb";
import * as fs from "fs";
import * as struct from "struct";

// ---------------------------------------------------------------------
// Wire protocol constants
// ---------------------------------------------------------------------

const FRAME_FROM_RADIO         = 0x3E;   // '>'
const FRAME_TO_RADIO           = 0x3C;   // '<'
const HEADER_BYTES             = 3;      // marker(1) + length LE(2)

const SMART_MAX_PAYLOAD        = 256;
const RESYNC_BUFFER_CAP        = 4096;
const MAX_TEXT_MESSAGE_LENGTH  = 200;

// Commands host -> radio.
const CMD_APP_START            = 0x01;
const CMD_SEND_DIRECT_MESSAGE  = 0x02;
const CMD_SEND_CHANNEL_MESSAGE = 0x03;
const CMD_ADD_UPDATE_CONTACT   = 0x09;
const CMD_SYNC_NEXT_MESSAGE    = 0x0A;
const CMD_SET_CHANNEL          = 0x20;
const CMD_SEND_ANON_REQ        = 0x39;

// Message responses radio -> host.
const RESP_MESSAGE_SENT        = 0x06;
const RESP_DIRECT_MSG_RECV     = 0x07;
const RESP_CHANNEL_MSG_RECV    = 0x08;
const RESP_NO_MORE_MESSAGES    = 0x0A;
const RESP_DIRECT_MSG_RECV_V3  = 0x10;
const RESP_CHANNEL_MSG_RECV_V3 = 0x11;
const RESP_CHANNEL_INFO        = 0x12;
const RESP_CHANNEL_DATA_RECV   = 0x1B;
const RESP_OK                  = 0x00;
const RESP_ERROR               = 0x01;
const PUSH_LOGIN_SUCCESS       = 0x85;
const PUSH_LOGIN_FAIL          = 0x86;

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
const MAX_CHANNEL_INDEX        = 7;
const UNKNOWN_LOG_INTERVAL     = 64;
const MAX_RESPONSE_CACHE       = 4;
const MAX_DIRECT_PREFIXES      = 16;
const DISCOVERY_NOTICE_INTERVAL = 300;

const TEXT_TYPE_PLAIN          = 0x00;
const TEXT_TYPE_CLI_DATA       = 0x01;
const TEXT_TYPE_SIGNED         = 0x02;
const MAX_CHANNEL_DATA_LENGTH  = 163;

function isDirectFrame(cmd)
{
    return cmd === RESP_DIRECT_MSG_RECV || cmd === RESP_DIRECT_MSG_RECV_V3;
}

function isGroupFrame(cmd)
{
    return cmd === RESP_CHANNEL_MSG_RECV || cmd === RESP_CHANNEL_MSG_RECV_V3;
}

function validTextPayload(cmd, payload)
{
    if (isDirectFrame(cmd)) {
        return length(payload) >= 9 && 9 + ord(payload, 8) <= length(payload);
    }
    if (isGroupFrame(cmd)) {
        return length(payload) >= 5;
    }
    return false;
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
let serialMode       = false;
let serialDevice     = null;
let serialBaud       = 115200;
let serialProfile    = "crow_zeros";
let nextReconnectTime = 0;
let strictHook       = null;
let channelDiscovery = false;
let discovery         = null;

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
let channelDataTextTypes = {};
let strictDirectIdentity = false;
let roomServers = [];
let pendingRoomLogins = {};
let roomLoginBootAttempted = false;
let pendingChannelProvision = null;
let connectionReady = false;

let directPrefixes = {};
let directPrefixOrder = [];
let lastDiscoveryNotice = 0;

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
    group_receive_unverified: 0,
    direct_identity_verified: 0,
    direct_identity_mismatch: 0,
    direct_identity_unverified: 0,
    direct_identity_dropped: 0,
    log_data_frames: 0,
    trace_data_frames: 0,
    telemetry_response_frames: 0,
    binary_response_frames: 0,
    control_data_frames: 0,
    channel_data_received: 0,
    channel_data_routed: 0,
    channel_data_unrouted: 0,
    channel_provisions_ok: 0,
    channel_provisions_failed: 0,
    room_servers_added: 0,
    room_logins_ok: 0,
    room_logins_failed: 0,
    message_sent_frames: 0,
    ack_frames: 0,
    unknown_frames: 0,
    unknown_frames_suppressed: 0,
    early_drop_unknown_cmd: 0,
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

function notifyIgnoredDiscovery(kind)
{
    const now = time();
    if (lastDiscoveryNotice && now - lastDiscoveryNotice < DISCOVERY_NOTICE_INTERVAL) {
        return;
    }
    lastDiscoveryNotice = now;
    notifyOperator([
        "<b>MeshCore discovery ignored</b>",
        `${kind} discovery is not retained by Crow.`,
        "Only direct messages and configured group-channel messages are kept."
    ], "meshcore-discovery-ignored");
}

function cacheResponse(cmd, payload)
{
    if (length(responses) >= MAX_RESPONSE_CACHE) {
        shift(responses);
    }
    push(responses, { cmd: cmd, payload: payload });
    stats.responses_cached++;
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
    // Keep encrypted binary frames out of the generic unknown-frame path when
    // strict Part 97 filtering is disabled.  Command 0x90 is also Companion's
    // contacts-full push and is handled by the discovery-drop branch above.
    if (cmd === CMD_ENCRYPTED_BIN) {
        return true;
    }
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
    if (slot === null || !chan) {
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
            channelCreated = true;
            return false;
        }
    }

    const chan = { namekey: channelNamekey, label: label };
    push(localChannels, chan);
    channel.updateLocalChannels(localChannels);
    rootConfig.update?.("channels");
    channelCreated = true;
    log0("auto-created channel: %s (label: %s)\n", channelNamekey, label);
    return true;
}

function mapDiscoveredChannelIfLocal(ch)
{
    if (!ch || ch.index === null || !ch.namekey) {
        return false;
    }
    const mapped = channel.getChannelByMeshcoreSlot(ch.index);
    if (mapped && mapped.namekey !== ch.namekey) {
        channel.clearMeshcoreSlotChannel(ch.index);
    }
    const chan = channel.getLocalChannelByNameKey(ch.namekey);
    if (chan) {
        mapMeshcoreSlot(ch.index, chan);
        return true;
    }
    return false;
}

function mapDiscoveredChannels()
{
    // Discovery may finish before channel.setup() has populated Crow's local
    // channel table. Re-apply the verified mappings on each backend tick so
    // that startup ordering cannot strand an otherwise exact tuple.
    for (let index in discoveredChannels) {
        mapDiscoveredChannelIfLocal(discoveredChannels[index]);
    }
}

// Called by the optional discovery module.  Configured slots remain in this
// core module because they are needed for normal message routing; only radio
// scanning and its transient request state live in meshcore_tcp_discovery.uc.
function acceptDiscoveredChannel(ch)
{
    if (!ch || ch.index === null || !ch.namekey) return null;
    const key = `${ch.index}`;
    const old = discoveredChannels[key];
    let action = null;
    if (!old) {
        discoveredChannels[key] = ch;
        action = "discovered";
    }
    else if (old.name !== ch.name || old.secret_b64 !== ch.secret_b64) {
        discoveredChannels[key] = ch;
        action = "updated";
    }
    mapDiscoveredChannelIfLocal(ch);
    return action;
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

    // MeshCore's built-in public channel is always slot 0 unless explicitly
    // overridden. This keeps group text working without radio discovery.
    register(config.meshcore_tcp_api?.public_channel_slot ??
        config.meshcore_serial_api?.public_channel_slot ?? 0,
        channel.meshcorePublicChannelNamekey());

    const slots = cfg?.channel_slots;
    if (type(slots) === "array") {
        for (let i = 0; i < length(slots); i++) {
            register(slots[i]?.slot, slots[i]?.namekey);
        }
    }
    else if (slots && type(slots) === "object") {
        for (let slot in slots) register(slot, slots[slot]);
    }

    const channels = config.channels ?? [];
    for (let i = 0; i < length(channels); i++) {
        if (channels[i]?.meshcore_slot != null) {
            register(channels[i].meshcore_slot, channels[i].namekey);
        }
    }
    mapDiscoveredChannels();
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

function meshcoreChannelIndexForNamekey(namekey)
{
    if (!namekey) {
        return null;
    }

    for (let idx in discoveredChannels) {
        if (discoveredChannels[idx]?.namekey === namekey && verifiedLocalChannelForSlot(int(idx), namekey)) {
            return int(idx);
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

function fieldCString(s)
{
    if (!s) return "";
    for (let i = 0; i < length(s); i++) {
        if (ord(s, i) === 0) return substr(s, 0, i);
    }
    return s;
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
    if (!prefix || length(prefix) < 4) return null;
    return u32le(prefix, 0);
}

function sameU32(a, b)
{
    return (a & 0xFFFFFFFF) === (b & 0xFFFFFFFF);
}

function directDestinationMatchesSelf(toId)
{
    if (toId === null || !meshcoreSelfPublicKeyPrefix) {
        return null;
    }
    const selfId = idFromPrefix(meshcoreSelfPublicKeyPrefix);
    if (selfId === null) {
        return null;
    }
    return sameU32(toId, selfId);
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
    if (id === null) {
        return null;
    }
    const remembered = directPrefixes[`${id}`];
    if (remembered) return remembered;
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

    const key = `${id}`;
    if (!directPrefixes[key]) push(directPrefixOrder, key);
    directPrefixes[key] = substr(prefix, 0, 6);
    while (length(directPrefixOrder) > MAX_DIRECT_PREFIXES) {
        delete directPrefixes[shift(directPrefixOrder)];
    }
}

function roomServerId(publicKey)
{
    if (!publicKey || length(publicKey) !== 32) return null;
    try {
        return struct.unpack(">I", publicKey)[0];
    }
    catch (_) {
        return null;
    }
}

function roomServerByTarget(target)
{
    if (!target) return null;
    const textTarget = `${target}`;
    for (let i = 0; i < length(roomServers); i++) {
        const server = roomServers[i];
        if (server.name === target || server.name === textTarget ||
            `${server.id}` === textTarget || server.short_name === target) {
            return server;
        }
    }
    return null;
}

function roomServerFromConfig(record)
{
    if (!record) return null;
    const encoded = record.public_key_b64 ?? record.public_key;
    if (!encoded) return null;

    let publicKey;
    try {
        publicKey = b64dec(encoded);
    }
    catch (_) {
        return null;
    }
    const id = roomServerId(publicKey);
    if (id === null) return null;

    const name = substr(record.name ?? "MeshCore Room Server", 0, 36);
    const shortName = substr(record.short_name ?? name, 0, 4);
    const server = {
        id: id,
        name: name,
        short_name: shortName,
        public_key: publicKey,
        public_key_b64: b64enc(publicKey),
        password: substr(record.password ?? "hello", 0, 15),
        sync_since: record.sync_since ?? 0
    };

    return server;
}

function loadRoomServers(config)
{
    roomServers = [];
    const records = cfg?.room_servers ?? config.meshcore_room_servers ?? [];
    if (type(records) !== "array") return;
    for (let i = 0; i < length(records); i++) {
        const server = roomServerFromConfig(records[i]);
        if (server) push(roomServers, server);
    }
}

function addLocalProvisionedChannel(provision)
{
    const namekey = `${provision.name} ${provision.key_b64}`;
    const localChannels = channel.getAllLocalChannels();
    let found = null;
    for (let i = 0; i < length(localChannels); i++) {
        if (localChannels[i].namekey === namekey) {
            found = localChannels[i];
            break;
        }
    }
    if (!found) {
        found = { namekey: namekey, label: `MeshCore~${provision.name}` };
        push(localChannels, found);
        channel.updateLocalChannels(localChannels);
        rootConfig.update?.("channels");
    }

    const discovered = {
        index: provision.slot,
        name: provision.name,
        secret: provision.secret,
        secret_b64: provision.key_b64,
        namekey: namekey
    };
    discoveredChannels[`${provision.slot}`] = discovered;
    mapDiscoveredChannelIfLocal(discovered);
}

function completeChannelProvision(ok)
{
    if (!pendingChannelProvision) return;
    const provision = pendingChannelProvision;
    pendingChannelProvision = null;
    if (!ok) {
        stats.channel_provisions_failed++;
        log0("private channel rejected slot=%d name=%s\n", provision.slot, provision.name);
        return;
    }
    stats.channel_provisions_ok++;
    addLocalProvisionedChannel(provision);
    log0("private channel provisioned slot=%d name=%s\n", provision.slot, provision.name);
}

function processRoomLogin(framePayload, success)
{
    const payload = substr(framePayload, 1);
    if (length(payload) < 8) return;
    const prefix = substr(payload, 2, 6);
    let server = null;
    for (let i = 0; i < length(roomServers); i++) {
        if (substr(roomServers[i].public_key, 0, 6) === prefix) {
            server = roomServers[i];
            break;
        }
    }
    if (!server) return;

    delete pendingRoomLogins[`${server.id}`];
    if (success) {
        stats.room_logins_ok++;
        log0("room server login accepted name=%s\n", server.name);
    }
    else {
        stats.room_logins_failed++;
        log0("room server login rejected name=%s\n", server.name);
    }
    global.event?.notify?.({ cmd: "node", id: server.id }, `room-server-${server.id}`);
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
    connectionReady = false;
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
    discovery?.resetScan?.();
}

function serialDeviceSafe(path)
{
    return path && match(path, /^\/dev\/[A-Za-z0-9._+\/-]+$/);
}

function configureSerial()
{
    if (!serialDeviceSafe(serialDevice)) {
        log0("serial device path rejected: %s\n", serialDevice ?? "");
        return false;
    }
    if (serialBaud < 1 || serialBaud > 4000000) {
        log0("serial baud rejected: %s\n", serialBaud);
        return false;
    }

    // USB CDC devices generally ignore baud, while USB UART bridges use it.
    // Keep the setup here so both classes receive the same raw 8N1 settings.
    if (!fs.access("/bin/stty")) {
        // Minimal AREDN images may omit stty.  CDC ACM devices use their
        // firmware defaults, so the absence of this optional helper must not
        // prevent opening the serial Companion device.
        log0("serial stty unavailable; using device defaults %s baud=%d\n",
            serialDevice, serialBaud);
        return true;
    }
    const rc = system(`/bin/stty -F ${serialDevice} ${serialBaud} raw -echo -ixon -ixoff cs8 -cstopb -parenb`);
    if (rc !== 0) {
        log0("serial stty failed device=%s baud=%d rc=%d\n", serialDevice, serialBaud, rc);
        return false;
    }
    return true;
}

function openSerial()
{
    if (!serialDeviceSafe(serialDevice)) {
        log0("serial device not configured; backend disabled\n");
        return null;
    }
    try {
        if (!configureSerial()) return null;
        const ns = fs.open(serialDevice, "r+");
        if (!ns) {
            log0("serial open failed %s\n", serialDevice);
            return null;
        }
        log0("opened MeshCore USB serial %s baud=%d profile=%s\n",
            serialDevice, serialBaud, serialProfile);
        stats.connects++;
        return ns;
    }
    catch (e) {
        log0("serial open failed %s: %s\n", serialDevice, e);
        nextReconnectTime = time() + RECONNECT_INTERVAL;
        return null;
    }
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

function openTransport()
{
    return serialMode ? openSerial() : openTcp();
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

function writeTransport(frame)
{
    // Preserve the AREDN ucode socket semantics: socket.send() is the
    // established TCP path and returns null after a successful write.
    if (!serialMode) {
        return s.send(frame);
    }

    let remaining = frame;
    let sent = 0;
    while (length(remaining) > 0) {
        const n = s.write(remaining);
        if (n === false) return -1;
        if (n === null || type(n) !== "number") {
            sent += length(remaining);
            break;
        }
        if (n <= 0) return -1;
        sent += n;
        remaining = substr(remaining, n);
    }
    // fs.open() returns a stdio-backed file handle for serial devices.  The
    // write is buffered unless explicitly flushed, so without this the radio
    // never sees the handshake or subsequent Companion commands.
    if (s.flush) s.flush();
    return sent;
}

export function sendCommand(cmd, payload)
{
    if (!s) return false;
    try {
        const frame = buildCommand(cmd, payload ?? "");
        const sent = writeTransport(frame);
        if (sent < 0) {
            closeSocket("command send failed");
            return false;
        }
        stats.commands_sent++;
        log1("send command=0x%02x frame_bytes=%d sent=%s\n", cmd, length(frame), sent);
        return true;
    }
    catch (_) {
        closeSocket("command send failed: " + socket.error());
        return false;
    }
};

function appStartPayloadFor(profile)
{
    if (profile === "meshcore_cli") {
        return chr(3) + "      " + "Crow";
    }
    return chr(0) + chr(0) + chr(0) + chr(0) + chr(0) + chr(0) + chr(0) + "Crow";
}

function appStartPayload()
{
    return appStartPayloadFor(serialMode ? serialProfile : "crow_zeros");
}

function sendBootHandshake()
{
    if (!s) return;
    try {
        const payload = appStartPayload();
        const frame = buildCommand(CMD_APP_START, payload);
        const sent = writeTransport(frame);
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

function fillBytes(value, count)
{
    let out = "";
    for (let i = 0; i < count; i++) out += chr(value);
    return out;
}

function buildSetChannelPayload(slot, name, secret)
{
    name = substr(name ?? "", 0, 32);
    let paddedName = name;
    while (length(paddedName) < 32) paddedName += chr(0);
    return chr(slot & 0xff) + paddedName + secret;
}

function buildRoomServerLoginPayload(publicKey, syncSince, password)
{
    password = substr(password ?? "hello", 0, 15);
    return publicKey + pack_le32(time()) + pack_le32(syncSince ?? 0) + password;
}

function buildRoomServerContactPayload(server)
{
    let name = substr(server.name ?? "MeshCore Room Server", 0, 32);
    while (length(name) < 32) name += chr(0);
    // An unknown path is required here. It makes the first room login flood
    // through the mesh instead of attempting a zero-hop direct send.
    return server.public_key + chr(3) + chr(0) + chr(0xFF) +
        fillBytes(0, 64) + name + pack_le32(0);
}

function sendRoomLoginRequest(server)
{
    const state = pendingRoomLogins[`${server.id}`];
    if (!state || !s) return false;
    const payload = buildRoomServerLoginPayload(server.public_key, server.sync_since, server.password);
    if (!sendCommand(CMD_SEND_ANON_REQ, payload)) return false;
    state.stage = "login";
    state.sent_at = time();
    log0("room server login sent name=%s\n", server.name);
    return true;
}

function loginConfiguredRoomServersOnBoot()
{
    if (roomLoginBootAttempted || !s || length(roomServers) === 0) return;
    roomLoginBootAttempted = true;

    // Make one bounded contact/login attempt for the configured room server
    // after each Crow process start.  The configured record supplies the
    // default `hello` guest password when no password is specified.
    for (let i = 0; i < length(roomServers); i++) {
        const server = roomServers[i];
        if (!server || pendingChannelProvision) continue;
        const id = `${server.id}`;
        if (pendingRoomLogins[id]) continue;
        pendingRoomLogins[id] = { server: server, stage: "contact", sent_at: time() };
        const ok = sendCommand(CMD_ADD_UPDATE_CONTACT, buildRoomServerContactPayload(server));
        if (!ok) delete pendingRoomLogins[id];
        if (ok) {
            log0("room server boot login scheduled name=%s\n", roomServers[i].name);
            break;
        }
    }
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

    // Firmware metadata between the public key and the name is binary and
    // differs by release.  The node name is the final printable ASCII tail;
    // parsing from an assumed fixed offset can display those metadata bytes
    // as part of the name on real Companion radios.
    let nameEnd = length(framePayload);
    while (nameEnd > 0 && ord(framePayload, nameEnd - 1) === 0) nameEnd--;
    let nameStart = nameEnd;
    while (nameStart > 0) {
        const byte = ord(framePayload, nameStart - 1);
        if (byte < 0x20 || byte > 0x7e) break;
        nameStart--;
    }
    const name = nameStart < nameEnd
        ? substr(framePayload, nameStart, nameEnd - nameStart) : null;

    if (name && length(name) > 0) {
        log0("parseSelfInfo: device name = %s\n", name);
        return name;
    }

    log1("parseSelfInfo: no printable name found\n");
    return null;
}

function directMsg(fromId, prefix, text, textType, timestamp, snr, pathLen, strong, toId)
{
    if (!text || length(text) === 0) {
        return null;
    }

    const directMatch = directDestinationMatchesSelf(toId);
    if (directMatch === null) {
        stats.direct_identity_unverified++;
        // Modern Companion direct receive frames carry the sender prefix but
        // no destination ID. Keep compatibility mode by default, while
        // allowing release deployments to require an explicit destination.
        if (strictDirectIdentity && toId === null) {
            stats.direct_identity_dropped++;
            log1("drop modern direct frame: destination identity unavailable\n");
            return null;
        }
    }
    else {
        stats.direct_identity_verified++;
        if (!directMatch) {
            stats.direct_identity_mismatch++;
        }
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
        to:                   toId ?? 0,
        rx_time:              timestamp ?? time(),
        hop_limit:            1,
        transport:            "meshcore",
        backend:              serialMode ? "serial_api" : "tcp_api",
        originating_callsign: callsign,
        namekey:              namekey,
        data: {
            text_message: text
        },
        metadata: {
            is_group_message: false,
            local_direct: directMatch === null ? true : directMatch,
            direct_identity_verified: directMatch !== null,
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
    if (!mapped || !verifiedLocalChannelForSlot(index, mapped.namekey)) {
        stats.group_receive_unverified++;
        log1("drop MeshCore group slot=%d until radio/Crow channel namekey matches\n", index);
        return null;
    }
    return {
        id:                   msgSeq,
        from:                 0,
        group_slot:           index,
        channel_index:        index,
        rx_time:              timestamp ?? time(),
        hop_limit:            1,
        transport:            "meshcore",
        backend:              serialMode ? "serial_api" : "tcp_api",
        originating_callsign: callsign,
        namekey:              mapped.namekey,
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

function channelDataTextTypeEnabled(dataType)
{
    return channelDataTextTypes[`${dataType}`] === true;
}

function validChannelDataPayload(payload)
{
    if (!payload || length(payload) < 9) return false;
    const index = ord(payload, 3);
    const dataLen = ord(payload, 7);
    return index <= MAX_CHANNEL_INDEX && dataLen <= MAX_CHANNEL_DATA_LENGTH &&
        8 + dataLen <= length(payload);
}

function parseChannelData(payload)
{
    // RESP_CHANNEL_DATA_RECV payload:
    // [snr][reserved:2][slot][path_len][data_type:2 LE][data_len][data].
    if (!validChannelDataPayload(payload)) return null;
    const rawSnr = ord(payload, 0);
    const snr = (rawSnr > 127 ? rawSnr - 256 : rawSnr) / 4.0;
    const index = ord(payload, 3);
    const pathLen = ord(payload, 4);
    const dataType = ord(payload, 5) | (ord(payload, 6) << 8);
    const dataLen = ord(payload, 7);
    stats.channel_data_received++;
    if (!channelDataTextTypeEnabled(dataType)) {
        stats.channel_data_unrouted++;
        log2("drop channel datagram type=0x%04x slot=%d len=%d (type not enabled)\n",
            dataType, index, dataLen);
        return null;
    }
    const text = textClean(substr(payload, 8, dataLen));
    if (!text || !isMostlyPrintable(text)) {
        stats.channel_data_unrouted++;
        log1("drop channel datagram type=0x%04x slot=%d (not printable text)\n",
            dataType, index);
        return null;
    }
    const msg = channelMsg(index, text, TEXT_TYPE_PLAIN, time(), snr, pathLen);
    if (!msg) {
        stats.channel_data_unrouted++;
        return null;
    }
    msg.metadata.channel_data = true;
    msg.metadata.channel_data_type = dataType;
    stats.channel_data_routed++;
    return msg;
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
    return directMsg(idFromPrefix(prefix), prefix, text, textType, timestamp, snr, pathLen, true, null);
}

function parseDirectLegacy(payload)
{
    if (length(payload) < 9) return null;
    const fromId = u32le(payload, 0);
    const toId = u32le(payload, 4);
    const tlen = ord(payload, 8);
    if (9 + tlen !== length(payload)) return null;
    const text = textClean(substr(payload, 9, tlen));
    if (!isMostlyPrintable(text)) return null;
    return directMsg(fromId, null, text, TEXT_TYPE_PLAIN, time(), null, null, true, toId);
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
        msg = parseDirectLegacy(payload) ?? parseDirectModern(payload, 3);
    }
    else if (cmd === RESP_DIRECT_MSG_RECV) {
        msg = parseDirectLegacy(payload) ?? parseDirectModern(payload, 1);
    }
    else if (cmd === RESP_CHANNEL_MSG_RECV_V3) {
        msg = parseChannelModern(payload, 3) ?? parseChannelLegacy(payload);
    }
    else if (cmd === RESP_CHANNEL_MSG_RECV) {
        msg = parseChannelModern(payload, 1) ?? parseChannelLegacy(payload);
    }
    else if (cmd === RESP_CHANNEL_DATA_RECV) {
        if (!validChannelDataPayload(payload)) {
            stats.early_drop_malformed_text++;
            log1("decode: malformed channel datagram len=%d\n", length(payload));
            return null;
        }
        // A valid but unconfigured data type/slot is intentionally unrouted,
        // not malformed. The parser updates the dedicated datagram counters.
        return parseChannelData(payload);
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
            connectionReady = true;
            syncRequestInFlight = false;
            const name = parseSelfInfo(framePayload);
            if (name) {
                deviceName = name;
                channelCreated = false;
            }
            discovery?.onSelfInfo?.();
            loginConfiguredRoomServersOnBoot();
            continue;
        }

        if (cmd === RESP_CHANNEL_INFO) {
            syncRequestInFlight = false;
            if (!discovery?.onChannelInfo?.(framePayload)) {
                notifyIgnoredDiscovery("Channel");
                maybeRequestNext("drop channel discovery");
            }
            continue;
        }

        if (cmd === RESP_OK || cmd === RESP_ERROR) {
            cacheResponse(cmd, framePayload);
            if (pendingChannelProvision) {
                completeChannelProvision(cmd === RESP_OK);
            }
            else {
                for (let id in pendingRoomLogins) {
                    const state = pendingRoomLogins[id];
                    if (state.stage === "contact") {
                        if (cmd === RESP_OK) {
                            if (!sendRoomLoginRequest(state.server)) {
                                delete pendingRoomLogins[id];
                                stats.room_logins_failed++;
                            }
                        }
                        else {
                            delete pendingRoomLogins[id];
                            stats.room_logins_failed++;
                            log0("room server contact add rejected name=%s error=%s\n",
                                state.server.name, length(framePayload) > 1 ? ord(framePayload, 1) : "unknown");
                        }
                        break;
                    }
                }
            }
            continue;
        }

        if (cmd === PUSH_LOGIN_SUCCESS || cmd === PUSH_LOGIN_FAIL) {
            processRoomLogin(framePayload, cmd === PUSH_LOGIN_SUCCESS);
            continue;
        }

        if (cmd === PUSH_CODE_NEW_ADVERT || cmd === PUSH_CODE_CONTACTS_FULL) {
            notifyIgnoredDiscovery("Contact");
            stats.early_drop_unknown_cmd++;
            syncRequestInFlight = false;
            maybeRequestNext("drop contact discovery");
            continue;
        }

        if (isDirectFrame(cmd) || isGroupFrame(cmd)) {
            syncRequestInFlight = false;
            if (!validTextPayload(cmd, payload)) {
                stats.early_drop_malformed_text++;
                log1("drop malformed text frame cmd=0x%02x plen=%d\n", cmd, plen);
                maybeRequestNext("drop malformed text");
                continue;
            }
            push(frames, { cmd: cmd, payload: payload });
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
            maybeRequestNext("channel data");
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
        stats.early_drop_unknown_cmd++;
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

function setupTransport(config, kind)
{
    if (discovery) {
        discovery.shutdown();
        discovery = null;
    }
    if (s) closeSocket("reconfigure");
    enabled = false;
    cfg = kind === "serial"
        ? (config.meshcore_serial_api ?? config.meshcore_usb_api)
        : config.meshcore_tcp_api;
    rootConfig = config;
    if (!cfg || cfg.enabled === false) {
        return;
    }
    enabled = true;

    serialMode = kind === "serial";

    callsign = config.callsign;
    router   = config.router;
    tcpHost  = cfg.host ?? DEFAULT_HOST;
    tcpPort  = cfg.port ?? DEFAULT_PORT;
    serialDevice = cfg.device ?? "/dev/ttyACM0";
    serialBaud = cfg.baud ?? 115200;
    serialProfile = cfg.app_start_profile ?? "crow_zeros";
    if (serialProfile !== "crow_zeros" && serialProfile !== "meshcore_cli") {
        serialProfile = "crow_zeros";
    }
    // Serial always uses explicitly configured slots. TCP channel scanning is
    // an optional module so the normal message path does not pay for its
    // parser, timer, or transient scan state.
    channelDiscovery = !serialMode && cfg.channel_discovery === true;
    channelDataTextTypes = {};
    const textTypes = cfg.channel_data_text_types;
    if (textTypes && type(textTypes) === "array") {
        for (let i = 0; i < length(textTypes); i++) {
            const dataType = int(textTypes[i]);
            if (dataType >= 1 && dataType <= 0xFFFF) {
                channelDataTextTypes[`${dataType}`] = true;
            }
        }
    }
    strictDirectIdentity = cfg.strict_direct_identity === true || cfg.direct_identity_mode === "verified";
    pendingRoomLogins = {};
    roomLoginBootAttempted = false;
    pendingChannelProvision = null;
    loadRoomServers(config);

    deviceName = cfg.device_name ?? null;
    channelCreated = ensureConfiguredPublicChannel(config);
    registerConfiguredChannelSlots(config);

    const gk = config._gatekeeper;
    strictHook = gk && type(gk.isEnabled) === "function"
        ? function () { return gk.isEnabled() === true; }
        : null;

    if (channelDiscovery) {
        try {
            discovery = require("meshcore_tcp_discovery_loader");
            discovery.setup({
                enabled: true,
                refresh_seconds: cfg.channel_refresh_seconds,
                sendCommand: sendCommand,
                onChannel: acceptDiscoveredChannel
            });
        }
        catch (e) {
            discovery = null;
            channelDiscovery = false;
            log0("unable to load optional channel discovery: %s\n", e);
        }
    }

    nextReconnectTime = 0;
    s = openTransport();
    if (s) sendBootHandshake();
};

export function setup(config)
{
    setupTransport(config, "tcp");
};

export function setupSerial(config)
{
    setupTransport(config, "serial");
};

export function shutdown()
{
    if (discovery) {
        discovery.shutdown();
        discovery = null;
    }
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
        // The ucode fs handle used for USB CDC serial is stdio-backed.  A
        // large read can block waiting for the full requested size even
        // after router.socket.poll() woke us for a few available bytes.  In
        // turn that stalls the whole Crow event loop, including the GUI.
        // Consume one byte per poll wakeup; the accumulator preserves frame
        // reassembly and the next router tick continues draining safely.
        const data = serialMode ? s.read(1) : s.recv(SOCKET_READ_CHUNK);
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
    if (idx === null || idx < 0 || idx > MAX_CHANNEL_INDEX ||
        !verifiedLocalChannelForSlot(idx, msg.namekey)) {
        stats.sends_failed++;
        stats.channel_sends_failed++;
        log1("send channel: unverified MeshCore slot/namekey namekey=%s slot=%s msg.id=%s\n",
            msg.namekey ?? "", idx ?? "", msg?.id);
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

export function addRoomServer(name, publicKeyB64, password)
{
    if (!cfg || !publicKeyB64) return false;
    let publicKey;
    try {
        publicKey = b64dec(publicKeyB64);
    }
    catch (_) {
        return false;
    }
    const id = roomServerId(publicKey);
    if (id === null) return false;

    let record = { name: substr(name ?? "MeshCore Room Server", 0, 36), public_key_b64: b64enc(publicKey) };
    if (password) record.password = substr(password, 0, 15);
    if (!cfg.room_servers || type(cfg.room_servers) !== "array") cfg.room_servers = [];
    let exists = false;
    for (let i = 0; i < length(cfg.room_servers); i++) {
        if (cfg.room_servers[i].public_key_b64 === record.public_key_b64) {
            cfg.room_servers[i] = record;
            exists = true;
            break;
        }
    }
    if (!exists) push(cfg.room_servers, record);

    loadRoomServers(rootConfig);
    rootConfig.update?.("meshcore_tcp_api");
    stats.room_servers_added++;
    return roomServerByTarget(record.name) !== null;
};

export function loginRoomServer(target)
{
    const server = roomServerByTarget(target);
    if (!s || !server || pendingChannelProvision) return false;
    const id = `${server.id}`;
    if (pendingRoomLogins[id]) return false;
    pendingRoomLogins[id] = { server: server, stage: "contact", sent_at: time() };
    const ok = sendCommand(CMD_ADD_UPDATE_CONTACT, buildRoomServerContactPayload(server));
    if (!ok) delete pendingRoomLogins[id];
    return ok;
};

export function provisionPrivateChannel(slot, name, keyB64)
{
    slot = int(slot);
    if (!s || slot < 1 || slot > MAX_CHANNEL_INDEX || !name || length(name) > 32 || !keyB64) {
        return false;
    }
    let secret;
    try {
        secret = b64dec(keyB64);
    }
    catch (_) {
        return false;
    }
    if (!secret || length(secret) !== 16 || pendingChannelProvision) return false;

    const provision = {
        slot: slot,
        name: substr(name, 0, 32),
        secret: secret,
        key_b64: b64enc(secret)
    };
    pendingChannelProvision = provision;
    if (!sendCommand(CMD_SET_CHANNEL, buildSetChannelPayload(slot, provision.name, secret))) {
        pendingChannelProvision = null;
        return false;
    }
    log0("private channel create sent slot=%d name=%s\n", slot, provision.name);
    return true;
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
    mapDiscoveredChannels();
    if (enabled && !s && time() >= nextReconnectTime) {
        nextReconnectTime = time() + RECONNECT_INTERVAL;
        s = openTransport();
        if (s) sendBootHandshake();
    }
    if (enabled && s && syncingMessages && !syncRequestInFlight && !pendingFull()) {
        maybeRequestNext(syncPausedBackpressure ? "resume after backpressure" : "tick resume");
    }
    discovery?.tick?.();
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
    const discoveryStatus = discovery?.status?.() ?? {};
    return {
        state: !s ? "disconnected" : (connectionReady ? "connected" : "connecting"),
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
        group_receive_unverified: stats.group_receive_unverified,
        last_rx_time: lastRxTime,
        last_cmd: lastCmd,
        syncing_messages: syncingMessages,
        sync_request_in_flight: syncRequestInFlight,
        sync_paused_backpressure: syncPausedBackpressure,
        channel_discovery: discoveryStatus.channel_discovery ?? false,
        channel_scans: discoveryStatus.channel_scans ?? 0,
        channel_discovery_requests: discoveryStatus.channel_discovery_requests ?? 0,
        channel_info_responses: discoveryStatus.channel_info_responses ?? 0,
        channel_discovery_timeouts: discoveryStatus.channel_discovery_timeouts ?? 0,
        channels_discovered: discoveryStatus.channels_discovered ?? 0,
        channels_updated: discoveryStatus.channels_updated ?? 0,
        direct_identity_verified: stats.direct_identity_verified,
        direct_identity_mismatch: stats.direct_identity_mismatch,
        direct_identity_unverified: stats.direct_identity_unverified,
        direct_identity_dropped: stats.direct_identity_dropped,
        direct_identity_mode: strictDirectIdentity ? "verified" : "compatibility",
        log_data_frames: stats.log_data_frames,
        trace_data_frames: stats.trace_data_frames,
        telemetry_response_frames: stats.telemetry_response_frames,
        binary_response_frames: stats.binary_response_frames,
        control_data_frames: stats.control_data_frames,
        channel_data_received: stats.channel_data_received,
        channel_data_routed: stats.channel_data_routed,
        channel_data_unrouted: stats.channel_data_unrouted,
        channel_data_text_types: keys(channelDataTextTypes),
        message_sent_frames: stats.message_sent_frames,
        ack_frames: stats.ack_frames,
        unknown_frames: stats.unknown_frames,
        unknown_frames_suppressed: stats.unknown_frames_suppressed,
        early_drop_unknown_cmd: stats.early_drop_unknown_cmd,
        transport: serialMode ? "serial" : "tcp",
        device: serialMode ? serialDevice : null,
        baud: serialMode ? serialBaud : null
    };
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

// CROW_TEST_HOOKS_BEGIN
// Parser/framing hooks used by the canonical ucode tests.

export function _test_inject(data, gatekeeperShim)
{
    if (gatekeeperShim !== null) {
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

export function _test_set_channel_data_text_types(types)
{
    channelDataTextTypes = {};
    for (let i = 0; i < length(types ?? []); i++) {
        const dataType = int(types[i]);
        if (dataType >= 1 && dataType <= 0xFFFF) {
            channelDataTextTypes[`${dataType}`] = true;
        }
    }
};

export function _test_set_strict_direct_identity(enabledMode)
{
    strictDirectIdentity = enabledMode === true;
};

export function _test_reset()
{
    if (discovery) {
        discovery.shutdown();
        discovery = null;
    }
    resetState();
    pendingRx = [];
    responses = [];
    msgSeq = 0;
    discoveredChannels = {};
    directPrefixes = {};
    directPrefixOrder = [];
    lastDiscoveryNotice = 0;
    channel.clearMeshcoreSlotChannels();
    unknownFrameCounts = {};
    meshcoreSelfPublicKey = null;
    meshcoreSelfPublicKeyPrefix = null;
    channelDataTextTypes = {};
    strictDirectIdentity = false;
    for (let k in stats) stats[k] = 0;
};

export function _test_set_local_channels(configs)
{
    return channel.setLocalChannels(configs ?? []);
};

export function _test_set_discovered_channel(index, namekey)
{
    const parts = split(namekey ?? "", " ");
    if (length(parts) !== 2) return false;
    discoveredChannels[`${index}`] = {
        index: index,
        name: parts[0],
        secret_b64: parts[1],
        namekey: namekey
    };
    return mapDiscoveredChannelIfLocal(discoveredChannels[`${index}`]);
};

export function _test_set_configured_channel(index, namekey)
{
    return _test_set_discovered_channel(index, namekey);
};

export function _test_decode_channel_info(framePayload)
{
    return require("meshcore_tcp_discovery_loader").parseChannelInfoForTest(framePayload);
};

export function _test_channel_send_allowed(index, namekey)
{
    return verifiedLocalChannelForSlot(index, namekey) !== null;
};

export function _test_map_discovered_channels()
{
    mapDiscoveredChannels();
};

export function _test_set_self_public_key_prefix(prefix)
{
    meshcoreSelfPublicKeyPrefix = prefix;
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

export function _test_app_start_payload_profile(profile)
{
    return buildCommand(CMD_APP_START, appStartPayloadFor(profile));
};

export function _test_build_direct_send(prefix, text, attempt)
{
    return buildCommand(CMD_SEND_DIRECT_MESSAGE, buildSendDirectPayload(prefix, text, attempt));
};

export function _test_build_channel_send(index, text)
{
    return buildCommand(CMD_SEND_CHANNEL_MESSAGE, buildSendChannelPayload(index, text));
};

export function _test_build_set_channel(slot, name, secret)
{
    return buildCommand(CMD_SET_CHANNEL, buildSetChannelPayload(slot, name, secret));
};

export function _test_build_room_login(publicKey, syncSince, password)
{
    return buildCommand(CMD_SEND_ANON_REQ, buildRoomServerLoginPayload(publicKey, syncSince, password));
};

export function _test_build_room_contact(name, publicKey)
{
    return buildCommand(CMD_ADD_UPDATE_CONTACT, buildRoomServerContactPayload({ name: name, public_key: publicKey }));
};
// CROW_TEST_HOOKS_END
