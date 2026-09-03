// =====================================================================
// Optional MeshCore TCP channel discovery
// =====================================================================
//
// This module is deliberately not imported by meshcore_tcp_api.uc at load
// time.  Channel discovery is disabled on small AREDN nodes unless an
// operator explicitly enables it.  Keeping the scanner and its parser out
// of the normal TCP message backend reduces both code and live state.
//

import * as channel from "channel";

const CMD_GET_CHANNEL          = 0x1f;
const RESP_CHANNEL_INFO        = 0x12;
const CHANNEL_RESPONSE_SIZE    = 50;
const MAX_CHANNEL_INDEX        = 7;
const CHANNEL_NAME_OFFSET      = 2;
const CHANNEL_NAME_LENGTH      = 32;
const SECRET_KEY_OFFSET        = 34;
const SECRET_KEY_LENGTH        = 16;
const DEFAULT_REFRESH_SECONDS  = 600;
const REQUEST_TIMEOUT_SECONDS  = 5;

let enabled = false;
let sendCommand = null;
let onChannel = null;
let refreshSeconds = DEFAULT_REFRESH_SECONDS;
let scanActive = false;
let scanNext = 0;
let requestInFlight = false;
let requestIndex = null;
let requestAt = 0;
let lastScan = 0;

let stats = {
    channel_scans: 0,
    channel_discovery_requests: 0,
    channel_info_responses: 0,
    channel_discovery_timeouts: 0,
    channels_discovered: 0,
    channels_updated: 0
};

function log0(fmt, ...args)
{
    DEBUG0("meshcore_tcp_discovery: " + fmt, ...args);
}

function log1(fmt, ...args)
{
    DEBUG1("meshcore_tcp_discovery: " + fmt, ...args);
}

function notifyChannelDiscovered(ch, action)
{
    const verb = action === "updated" ? "updated" : "discovered";
    try {
        global.event?.queue?.({ cmd: "/reply", reply: [
            `<b>MeshCore TCP API</b> ${verb} channel`,
            `Index ${ch.index}: ${ch.name}`,
            "Runtime only; not saved to Crow config."
        ] });
        global.event?.notify?.({ cmd: "channels" }, `meshcore-tcp-channel-${ch.index}`);
    }
    catch (_) {}
}

function fieldCString(value)
{
    if (!value) return "";
    for (let i = 0; i < length(value); i++) {
        if (ord(value, i) === 0) return substr(value, 0, i);
    }
    return value;
}

function byteAt(data, off)
{
    return type(data) === "array" ? data[off] : ord(data, off);
}

function isAllZeros(data)
{
    if (!data) return true;
    for (let i = 0; i < length(data); i++) {
        if (byteAt(data, i) !== 0) return false;
    }
    return true;
}

function parseChannelInfo(data)
{
    if (!data || length(data) < CHANNEL_RESPONSE_SIZE ||
        byteAt(data, 0) !== RESP_CHANNEL_INFO) {
        return null;
    }

    const index = byteAt(data, 1);
    if (index > MAX_CHANNEL_INDEX) return null;

    const name = fieldCString(substr(data, CHANNEL_NAME_OFFSET, CHANNEL_NAME_LENGTH));
    const secret = substr(data, SECRET_KEY_OFFSET, SECRET_KEY_LENGTH);
    if (!name || length(secret) !== SECRET_KEY_LENGTH || isAllZeros(secret)) {
        return null;
    }

    const publicNamekey = channel.meshcorePublicChannelNamekey();
    const publicParts = split(publicNamekey, " ");
    const isBuiltInPublic = name === "Public" && length(publicParts) === 2 &&
        secret === b64dec(publicParts[1]);

    return {
        index: index,
        name: name,
        secret: secret,
        secret_b64: b64enc(secret),
        namekey: isBuiltInPublic ? publicNamekey : `${name} ${b64enc(secret)}`
    };
}

function request(index, reason)
{
    if (!enabled || !sendCommand || index < 0 || index > MAX_CHANNEL_INDEX) {
        return false;
    }
    requestInFlight = true;
    requestIndex = index;
    requestAt = time();
    stats.channel_discovery_requests++;
    log1("channel discovery request index=%d reason=%s\n", index, reason ?? "unknown");
    if (!sendCommand(CMD_GET_CHANNEL, chr(index))) {
        requestInFlight = false;
        requestIndex = null;
        return false;
    }
    return true;
}

function continueScan(reason)
{
    if (!enabled || !scanActive || requestInFlight) return;
    if (scanNext > MAX_CHANNEL_INDEX) {
        scanActive = false;
        lastScan = time();
        log1("channel discovery scan complete\n");
        return;
    }
    request(scanNext++, reason);
}

function startScan(reason)
{
    if (!enabled || scanActive) return;
    scanActive = true;
    scanNext = 0;
    requestInFlight = false;
    requestIndex = null;
    stats.channel_scans++;
    continueScan(reason);
}

export function setup(options)
{
    // Do not call the later exported shutdown() declaration here. AREDN's
    // ucode binding does not make that declaration available as a local
    // function before its source position.
    enabled = false;
    sendCommand = null;
    onChannel = null;
    scanActive = false;
    requestInFlight = false;
    requestIndex = null;
    requestAt = 0;
    lastScan = 0;
    sendCommand = options?.sendCommand;
    onChannel = options?.onChannel;
    refreshSeconds = options?.refresh_seconds ?? DEFAULT_REFRESH_SECONDS;
    if (refreshSeconds < 60) refreshSeconds = 60;
    enabled = options?.enabled === true && type(sendCommand) === "function";
    if (enabled) log0("optional channel discovery enabled\n");
};

export function shutdown()
{
    enabled = false;
    sendCommand = null;
    onChannel = null;
    scanActive = false;
    requestInFlight = false;
    requestIndex = null;
    requestAt = 0;
    lastScan = 0;
};

// Preserve cumulative counters across reconnects, but abandon an in-flight
// scan so a response from the previous USB/TCP session cannot block the next
// connection's scan.
export function resetScan()
{
    scanActive = false;
    scanNext = 0;
    requestInFlight = false;
    requestIndex = null;
    requestAt = 0;
};

export function onSelfInfo()
{
    startScan("self-info");
};

export function onChannelInfo(framePayload)
{
    if (!enabled || !requestInFlight) return false;
    stats.channel_info_responses++;
    requestInFlight = false;
    requestIndex = null;

    const ch = parseChannelInfo(framePayload);
    if (ch && onChannel) {
        const action = onChannel(ch);
        if (action === "discovered") {
            stats.channels_discovered++;
            notifyChannelDiscovered(ch, action);
        }
        if (action === "updated") {
            stats.channels_updated++;
            notifyChannelDiscovered(ch, action);
        }
    }
    continueScan(ch ? "channel-info" : "bad-channel-info");
    return true;
};

export function tick()
{
    if (!enabled) return;
    if (requestInFlight && time() - requestAt >= REQUEST_TIMEOUT_SECONDS) {
        stats.channel_discovery_timeouts++;
        log1("channel discovery timeout index=%s\n", requestIndex);
        requestInFlight = false;
        requestIndex = null;
        continueScan("timeout");
    }
    if (!scanActive && lastScan && time() - lastScan >= refreshSeconds) {
        startScan("periodic refresh");
    }
};

export function status()
{
    return {
        channel_discovery: enabled,
        channel_scans: stats.channel_scans,
        channel_discovery_requests: stats.channel_discovery_requests,
        channel_info_responses: stats.channel_info_responses,
        channel_discovery_timeouts: stats.channel_discovery_timeouts,
        channels_discovered: stats.channels_discovered,
        channels_updated: stats.channels_updated,
        scan_active: scanActive,
        request_in_flight: requestInFlight
    };
};

// CROW_TEST_HOOKS_BEGIN
export function decodeChannelInfoForTest(data)
{
    return parseChannelInfo(data);
};

export function parseChannelInfoForTest(data)
{
    if (!data || length(data) < CHANNEL_RESPONSE_SIZE ||
        byteAt(data, 0) !== RESP_CHANNEL_INFO) {
        return null;
    }
    const index = byteAt(data, 1);
    if (index > MAX_CHANNEL_INDEX) return null;

    const nameBytes = [];
    for (let i = 0; i < CHANNEL_NAME_LENGTH; i++) {
        push(nameBytes, byteAt(data, CHANNEL_NAME_OFFSET + i) ?? 0);
    }
    let name = "";
    for (let i = 0; i < length(nameBytes); i++) {
        if (nameBytes[i] === 0) break;
        name += chr(nameBytes[i]);
    }
    const secret = [];
    for (let i = 0; i < SECRET_KEY_LENGTH; i++) {
        push(secret, byteAt(data, SECRET_KEY_OFFSET + i) ?? 0);
    }
    return {
        packet_id: RESP_CHANNEL_INFO,
        channel_index: index,
        channel_name: name,
        secret_key: secret,
        is_configured: length(name) > 0 && !isAllZeros(secret),
        raw_name_bytes: nameBytes,
        raw_key_bytes: secret
    };
};
// CROW_TEST_HOOKS_END
