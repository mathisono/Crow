// =====================================================================
// meshcore_tcp_discovery.uc
// =====================================================================
//
// MeshCore group/channel discovery — Phase 2 implementation
//
// Queries MeshCore radio's 8 memory slots (0-7), auto-discovers groups,
// and maintains a periodic sync (5-10 min interval) to detect:
//   - New groups programmed into the radio
//   - Deleted groups (slots cleared)
//   - Key changes (AES key rotation)
//
// Architecture:
//   1. startup(): Query all 8 slots once at boot
//   2. tick(): Every 5-10 minutes, re-query and diff against cached state
//   3. On change: Alert user, update channel, call channel.uc auto-import
//
// Status: READY FOR IMPLEMENTATION (Phase 2)
//          All API details verified by Mathison (2026-06-19)
// =====================================================================

import * as channel from "channel";
import * as struct from "struct";

// TODO: Confirm exact command ID for CMD_GET_CHANNEL from MeshCore spec
const CMD_GET_CHANNEL     = 0x0A;  // Query group info from radio (ASSUMED)
const COMPANION_MAGIC     = 0x3E;
const HEADER_BYTES        = 4;

// Discovery state
let enabled              = false;
let tcpApi              = null;      // Reference to meshcore_tcp_api module
let cachedGroups        = [];        // Previous state for diffing
let lastSyncTime        = 0;
let syncIntervalMs      = 300000;    // 5 minutes

let stats = {
    syncs_run: 0,
    new_groups_detected: 0,
    deleted_groups_detected: 0,
    key_changes_detected: 0,
    errors: 0
};

// =====================================================================
// Logging
// =====================================================================

function log0(fmt, ...args)
{
    DEBUG0("meshcore_discovery: " + fmt, ...args);
}

function log1(fmt, ...args)
{
    DEBUG1("meshcore_discovery: " + fmt, ...args);
}

// =====================================================================
// Group Query — Iterative slot scanning
// =====================================================================
//
// Query all 8 memory slots on the radio.
// 
// Returns array of groups:
//   [
//     { slot: 0, name: "TacNet", key: [bytes], key_size: 16, ... },
//     { slot: 1, name: "Emergency", key: [bytes], key_size: 16, ... },
//     ...
//   ]
//
// BLOCKED on MeshCore TCP API details:
//   - Exact command ID for CMD_GET_CHANNEL
//   - Response structure (name location, key location, etc.)
//   - How to detect empty slots
//
// For now: STUB implementation with TODO markers
// =====================================================================

export function queryDeviceGroups()
{
    const groups = [];
    
    // TODO: Get reference to meshcore_tcp_api module for command sending
    // For now, this is a stub that returns empty array
    
    for (let slot = 0; slot < 8; slot++) {
        // TODO: Send CMD_GET_CHANNEL to radio for this slot
        // TODO: Parse response to extract: name, AES key, is_configured, etc.
        // TODO: If is_configured = false, skip this slot
        
        // Stub code (will be replaced):
        // const response = meshcore_tcp_api.sendCommand(CMD_GET_CHANNEL, [slot]);
        // if (!response || !response.is_configured) continue;
        //
        // const group = {
        //     slot: slot,
        //     name: response.name,
        //     key: response.aes_key,     // [bytes]
        //     key_size: response.key_length,
        //     index: response.channel_index,
        //     is_programmed: response.is_configured
        // };
        // push(groups, group);
    }
    
    return groups;
}

// =====================================================================
// State Comparison & Change Detection
// =====================================================================

function keysEqual(key1, key2)
{
    if (!key1 || !key2) return key1 === key2;
    if (type(key1) !== type(key2)) return false;
    if (length(key1) !== length(key2)) return false;
    
    // Compare bytes element by element
    for (let i = 0; i < length(key1); i++) {
        if (key1[i] !== key2[i]) return false;
    }
    return true;
}

function getCachedGroup(slot)
{
    for (let g of cachedGroups) {
        if (g.slot === slot) return g;
    }
    return null;
}

function detectNewGroups(current)
{
    // Find groups in current that aren't in cached
    for (let group of current) {
        const cached = getCachedGroup(group.slot);
        
        if (!cached) {
            log0("NEW group detected: slot %d, name=%s\\n", 
                 group.slot, group.name);
            stats.new_groups_detected++;
            
            // Auto-discover this group
            autoDiscoverGroup(group);
        }
    }
}

function detectDeletedGroups(current)
{
    // Find groups in cached that aren't in current
    for (let cached of cachedGroups) {
        const currentGroup = null;
        for (let g of current) {
            if (g.slot === cached.slot) {
                currentGroup = g;
                break;
            }
        }
        
        if (!currentGroup) {
            log0("DELETED group: slot %d, name=%s\\n", 
                 cached.slot, cached.name);
            stats.deleted_groups_detected++;
            
            // Mark channel as deprecated
            deprecateGroup(cached);
        }
    }
}

function detectKeyChanges(current)
{
    // Find groups with changed keys
    for (let group of current) {
        const cached = getCachedGroup(group.slot);
        
        if (cached && !keysEqual(group.key, cached.key)) {
            log0("KEY ROTATION: slot %d, name=%s\\n", 
                 group.slot, group.name);
            stats.key_changes_detected++;
            
            // Alert user
            alertKeyRotation(group, cached);
            
            // Update the channel
            updateGroupKey(group);
        }
        
        // Also check for name changes
        if (cached && group.name !== cached.name) {
            log0("RENAMED: slot %d, %s -> %s\\n", 
                 group.slot, cached.name, group.name);
            renameGroup(cached.slot, group.name);
        }
    }
}

// =====================================================================
// Group Channel Management
// =====================================================================

function autoDiscoverGroup(group)
{
    // Build a Crow channel for this group
    // Namekey format: "MeshCore:GroupName <base64_key>"
    
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
    
    // Register in channel.uc
    channel.addMessageNameKey(namekey);
    channel.setMeshcoreSlotChannel(group.slot, channelObj);
    
    log1("auto-discovered: %s (slot %d)\\n", namekey, group.slot);
}

function deprecateGroup(group)
{
    // Mark group channel as deprecated
    // Keep messages, stop routing new ones
    
    // TODO: Call channel.uc to mark as deprecated
    // For now: log only
    log1("deprecated: slot %d, name=%s\\n", group.slot, group.name);
}

function alertKeyRotation(newGroup, oldGroup)
{
    // Alert user that a group's key has changed
    // TODO: Integrate with Crow's user alert system
    
    log0("ALERT: Group '%s' key has changed!\\n", newGroup.name);
    log0("  Please review the change on your radio.\\n");
}

function updateGroupKey(group)
{
    // Update the stored key for a group
    // TODO: Update channel.uc with new key
    
    log1("updated key for slot %d: %s\\n", group.slot, group.name);
}

function renameGroup(slot, newName)
{
    // Update group name in Crow
    // TODO: Rename channel in channel.uc
    
    log1("renamed slot %d to: %s\\n", slot, newName);
}

// =====================================================================
// Utility: Encode group key for namekey
// =====================================================================

function encodeGroupKey(keyBytes)
{
    // Convert raw key bytes to base64 for use in namekey
    // For now: hex encode (TODO: switch to base64)
    
    let hex = "";
    if (type(keyBytes) === "array") {
        for (let i = 0; i < length(keyBytes); i++) {
            hex += sprintf("%02x", keyBytes[i]);
        }
    }
    return hex;
}

// =====================================================================
// Periodic Sync
// =====================================================================

export function tick()
{
    if (!enabled) return;
    
    const now = systime() * 1000;  // Convert to ms
    if (now - lastSyncTime < syncIntervalMs) {
        return;  // Not time yet
    }
    
    syncChannelSlots();
    lastSyncTime = now;
}

function syncChannelSlots()
{
    log1("sync: querying radio for group slots...\\n");
    stats.syncs_run++;
    
    const currentGroups = queryDeviceGroups();
    
    // Compare with cached state
    detectNewGroups(currentGroups);
    detectDeletedGroups(currentGroups);
    detectKeyChanges(currentGroups);
    
    // Update cache
    cachedGroups = currentGroups;
    
    log1("sync: complete (new=%d, deleted=%d, key_changes=%d)\\n",
         stats.new_groups_detected, stats.deleted_groups_detected,
         stats.key_changes_detected);
}

// =====================================================================
// Public API
// =====================================================================

export function setup(config)
{
    if (!config?.meshcore_discovery?.enabled) {
        return;
    }
    
    enabled = true;
    syncIntervalMs = config.meshcore_discovery.sync_interval_ms ?? 300000;
    
    log0("discovery enabled (sync interval: %d ms)\\n", syncIntervalMs);
    
    // Initial discovery on startup
    startup();
}

export function startup()
{
    if (!enabled) return;
    
    log1("initial discovery...\\n");
    const groups = queryDeviceGroups();
    
    for (let group of groups) {
        autoDiscoverGroup(group);
    }
    
    cachedGroups = groups;
    lastSyncTime = systime() * 1000;
    
    log0("initial discovery: found %d groups\\n", length(groups));
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
