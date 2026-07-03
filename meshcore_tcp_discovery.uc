// =====================================================================
// meshcore_tcp_discovery.uc
// =====================================================================
//
// MeshCore group/channel discovery for the TCP / Serial-WiFi API path.
//
// Discovery asks the radio for memory slots 0-7 using:
//
//     CMD_GET_CHANNEL = 0x1F
//
// The corrected TCP transport is provided by meshcore_tcp_api.uc, which
// now sends client-to-radio frames as:
//
//     [ '<' ][ length LSB ][ length MSB ][ command + payload ]
//
// Channel responses are cached by meshcore_tcp_api.uc when radio-to-client
// frames arrive as:
//
//     [ '>' ][ length LSB ][ length MSB ][ 0x12 + channel-info payload ]
//
// queryDeviceGroups() sends slot queries and drains any cached 0x12
// responses that have already arrived. This keeps discovery non-blocking;
// the periodic sync will pick up responses as the backend receives them.
//
// =====================================================================

import * as channel from "channel";
import * as meshcoreTcpApi from "meshcore_tcp_api";

const CMD_GET_CHANNEL             = 0x1F;
const PACKET_CHANNEL_INFO         = 0x12;

const CHANNEL_RESPONSE_SIZE        = 50;
const CHANNEL_RESPONSE_ID_OFFSET   = 0;
const CHANNEL_INDEX_OFFSET         = 1;
const CHANNEL_NAME_OFFSET          = 2;
const CHANNEL_NAME_LENGTH          = 32;
const SECRET_KEY_OFFSET            = 34;
const SECRET_KEY_LENGTH            = 16;

let enabled              = false;
let cachedGroups        = [];
let lastSyncTime        = 0;
let syncIntervalMs      = 300000;

let stats = {
    syncs_run: 0,
    queries_sent: 0,
    responses_seen: 0,
    new_groups_detected: 0,
    deleted_groups_detected: 0,
    key_changes_detected: 0,
    errors: 0
};

function log0(fmt, ...args)
{
    DEBUG0("meshcore_discovery: " + fmt, ...args);
}

function log1(fmt, ...args)
{
    DEBUG1("meshcore_discovery: " + fmt, ...args);
}

function byteAt(data, off)
{
    return type(data) === "array" ? data[off] : ord(data, off);
}

function parseChannelInfo(data)
{
    if (!data || length(data) < CHANNEL_RESPONSE_SIZE) {
        log1("parseChannelInfo: insufficient data (%d bytes)\n", length(data) ?? 0);
        return null;
    }

    const packetId = byteAt(data, CHANNEL_RESPONSE_ID_OFFSET);
    if (packetId !== PACKET_CHANNEL_INFO) {
        log1("parseChannelInfo: wrong packet type (got 0x%02x, expected 0x%02x)\n",
             packetId, PACKET_CHANNEL_INFO);
        return null;
    }

    const channelIndex = byteAt(data, CHANNEL_INDEX_OFFSET);
    if (channelIndex > 7) {
        log1("parseChannelInfo: invalid channel index %d\n", channelIndex);
        return null;
    }

    let nameBytes = [];
    for (let i = 0; i < CHANNEL_NAME_LENGTH; i++) {
        push(nameBytes, byteAt(data, CHANNEL_NAME_OFFSET + i) ?? 0);
    }

    let nameStr = "";
    for (let i = 0; i < length(nameBytes); i++) {
        const b = nameBytes[i];
        if (b === 0x00) break;
        nameStr += chr(b);
    }

    let secretKey = [];
    for (let i = 0; i < SECRET_KEY_LENGTH; i++) {
        push(secretKey, byteAt(data, SECRET_KEY_OFFSET + i) ?? 0);
    }

    const isConfigured = (length(nameStr) > 0) && !isAllZeros(secretKey);

    return {
        packet_id: packetId,
        channel_index: channelIndex,
        channel_name: nameStr,
        secret_key: secretKey,
        is_configured: isConfigured,
        raw_name_bytes: nameBytes,
        raw_key_bytes: secretKey
    };
}

function isAllZeros(data)
{
    if (!data) return true;
    for (let i = 0; i < length(data); i++) {
        if (data[i] !== 0x00) return false;
    }
    return true;
}

function groupFromParsed(parsed)
{
    return {
        slot: parsed.channel_index,
        name: parsed.channel_name,
        key: parsed.secret_key,
        key_size: SECRET_KEY_LENGTH,
        is_programmed: parsed.is_configured,
        timestamp: systime()
    };
}

export function queryDeviceGroups()
{
    const groups = [];

    for (let slot = 0; slot < 8; slot++) {
        if (meshcoreTcpApi.sendCommand(CMD_GET_CHANNEL, chr(slot))) {
            stats.queries_sent++;
        }
        else {
            stats.errors++;
            log1("slot %d: unable to send CMD_GET_CHANNEL\n", slot);
        }
    }

    for (let i = 0; i < 8; i++) {
        const response = meshcoreTcpApi.takeResponse(PACKET_CHANNEL_INFO);
        if (!response) {
            break;
        }
        stats.responses_seen++;

        const parsed = parseChannelInfo(response.payload);
        if (!parsed) {
            stats.errors++;
            continue;
        }
        if (!parsed.is_configured) {
            log1("slot %d: empty\n", parsed.channel_index);
            continue;
        }

        const group = groupFromParsed(parsed);
        push(groups, group);
        log1("slot %d: %s (%d-byte key)\n", group.slot, group.name, group.key_size);
    }

    log0("discovered %d groups from cached TCP responses\n", length(groups));
    return groups;
}

function keysEqual(key1, key2)
{
    if (!key1 || !key2) return key1 === key2;
    if (type(key1) !== type(key2)) return false;
    if (length(key1) !== length(key2)) return false;
    for (let i = 0; i < length(key1); i++) {
        if (key1[i] !== key2[i]) return false;
    }
    return true;
}

function getCachedGroup(slot)
{
    for (let group of cachedGroups) {
        if (group.slot === slot) return group;
    }
    return null;
}

function detectNewGroups(current)
{
    for (let group of current) {
        if (!getCachedGroup(group.slot)) {
            log0("NEW group detected: slot %d, name=%s\n", group.slot, group.name);
            stats.new_groups_detected++;
            autoDiscoverGroup(group);
        }
    }
}

function detectDeletedGroups(current)
{
    for (let cached of cachedGroups) {
        let found = false;
        for (let group of current) {
            if (group.slot === cached.slot) {
                found = true;
                break;
            }
        }
        if (!found) {
            log0("DELETED group: slot %d, name=%s\n", cached.slot, cached.name);
            stats.deleted_groups_detected++;
            deprecateGroup(cached);
        }
    }
}

function detectKeyChanges(current)
{
    for (let group of current) {
        const cached = getCachedGroup(group.slot);
        if (cached && !keysEqual(group.key, cached.key)) {
            log0("KEY ROTATION: slot %d, name=%s\n", group.slot, group.name);
            stats.key_changes_detected++;
            alertKeyRotation(group, cached);
            updateGroupKey(group);
        }
        if (cached && group.name !== cached.name) {
            log0("RENAMED: slot %d, %s -> %s\n", group.slot, cached.name, group.name);
            renameGroup(cached.slot, group.name);
        }
    }
}

function autoDiscoverGroup(group)
{
    const keyStr = encodeGroupKey(group.key);
    const namekey = sprintf("MeshCore:%s %s", group.name, keyStr);

    const channelObj = {
        namekey: namekey,
        name: group.name,
        source: "meshcore",
        slot_index: group.slot,
        key: group.key,
        is_group_message: true,
        auto_discovered: true,
        created_time: systime(),
        last_sync_time: systime()
    };

    channel.addMessageNameKey(namekey);
    channel.setMeshcoreSlotChannel(group.slot, channelObj);

    log1("auto-discovered: %s (slot %d)\n", namekey, group.slot);
}

function deprecateGroup(group)
{
    log1("deprecated: slot %d, name=%s\n", group.slot, group.name);
}

function alertKeyRotation(newGroup, oldGroup)
{
    log0("ALERT: Group '%s' key has changed!\n", newGroup.name);
    log0("  Please review the change on your radio.\n");
}

function updateGroupKey(group)
{
    log1("updated key for slot %d: %s\n", group.slot, group.name);
}

function renameGroup(slot, newName)
{
    log1("renamed slot %d to: %s\n", slot, newName);
}

function encodeGroupKey(keyBytes)
{
    let raw = "";
    if (type(keyBytes) === "array") {
        for (let i = 0; i < length(keyBytes); i++) {
            raw += chr(keyBytes[i] & 0xFF);
        }
    }
    else {
        raw = keyBytes ?? "";
    }
    return b64enc(raw);
}

export function tick()
{
    if (!enabled) return;

    const now = systime() * 1000;
    if (now - lastSyncTime < syncIntervalMs) {
        return;
    }

    syncChannelSlots();
    lastSyncTime = now;
}

function syncChannelSlots()
{
    log1("sync: querying radio for group slots...\n");
    stats.syncs_run++;

    const currentGroups = queryDeviceGroups();

    detectNewGroups(currentGroups);
    detectDeletedGroups(currentGroups);
    detectKeyChanges(currentGroups);

    cachedGroups = currentGroups;

    log1("sync: complete (new=%d, deleted=%d, key_changes=%d)\n",
         stats.new_groups_detected, stats.deleted_groups_detected,
         stats.key_changes_detected);
}

export function setup(config)
{
    if (!config?.meshcore_discovery?.enabled) {
        return;
    }

    enabled = true;
    syncIntervalMs = config.meshcore_discovery.sync_interval_ms ?? 300000;

    log0("discovery enabled (sync interval: %d ms)\n", syncIntervalMs);
    startup();
}

export function startup()
{
    if (!enabled) return;

    log1("initial discovery...\n");
    const groups = queryDeviceGroups();

    for (let group of groups) {
        autoDiscoverGroup(group);
    }

    cachedGroups = groups;
    lastSyncTime = systime() * 1000;

    log0("initial discovery: found %d groups\n", length(groups));
}

export function shutdown()
{
    enabled = false;
}

export function getStats()
{
    return stats;
}

export function getCachedGroups()
{
    return cachedGroups;
}

export function getSyncStatus()
{
    return {
        enabled: enabled,
        last_sync_time: lastSyncTime,
        next_sync_in_ms: max(0, syncIntervalMs - (systime() * 1000 - lastSyncTime)),
        cached_groups: length(cachedGroups),
        stats: stats
    };
}

export function parseChannelInfoForTest(data)
{
    return parseChannelInfo(data);
}
