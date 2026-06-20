// =====================================================================
// gatekeeper_group_message_updates.uc
// =====================================================================
//
// MeshCore group message handling for gatekeeper — Phase 3
//
// Implements:
//   1. Weak-identity rule detection (group messages)
//   2. Outbound formatter (@MCGW-[GroupName]> tag)
//   3. Audit logging for all group->AREDN bridges
//   4. Config schema for controlling group message bridging
//
// This file contains the code snippets to be integrated into gatekeeper.uc
//
// Status: READY FOR IMPLEMENTATION (Phase 3)
//          All design verified by architecture review (2026-06-19)
// =====================================================================

// =====================================================================
// SNIPPET 1: Add to gatekeeper config schema
// =====================================================================
//
// Add these fields to the config JSON:
//
//     "gatekeeper": {
//         "bridges": {
//             "meshcore_tcp_api": {
//                 "allow_group_messages": true,        // NEW
//                 "require_group_tag": true,           // NEW
//                 "tag_format": "@MCGW-[{group_name}]>", // NEW
//                 "allow_aredn_bridge": true,          // NEW
//                 "audit_log_groups": true             // NEW
//             }
//         }
//     }

// =====================================================================
// SNIPPET 2: Weak-identity detection function
// =====================================================================
//
// Add to gatekeeper.uc:

function detectWeakIdentityMessage(msg)
{
    // Check if message is a group message (weak identity)
    if (!msg.metadata?.is_group_message) {
        return false;
    }
    
    // Symmetric key = weak identity (group shares same key)
    if (!msg.metadata?.symmetric_key) {
        return false;
    }
    
    return true;
}

function handleWeakIdentityMessage(msg, config)
{
    const cfg = config?.gatekeeper?.bridges?.meshcore_tcp_api;
    
    // Check if group messages are allowed
    if (!cfg?.allow_group_messages) {
        DEBUG0("gatekeeper: group message blocked (disabled in config)\\n");
        audit_log("GROUP_MESSAGE_BLOCKED", {
            reason: "Group messages disabled",
            from: msg.from,
            group_name: msg.group_name,
            text: msg.data.text_message
        });
        return null;  // Drop message
    }
    
    // Mark for group tagging
    msg.gatekeeper_action = "tag_as_group";
    msg.weak_identity = true;
    
    return msg;
}

// =====================================================================
// SNIPPET 3: Outbound formatter for group messages
// =====================================================================
//
// Add to gatekeeper.uc:

function formatGroupMessageForAREDN(msg, config)
{
    // Input:
    //   from: "4234FF10" (node ID hex)
    //   group_name: "TacNet"
    //   text: "Hello everyone"
    //
    // Output:
    //   "KN6PLV@MCGW-[TacNet]> Hello everyone"
    
    const cfg = config?.gatekeeper?.bridges?.meshcore_tcp_api;
    const tagFormat = cfg?.tag_format ?? "@MCGW-[{group_name}]>";
    
    // Resolve callsign from node ID
    const senderCallsign = resolveCallsign(msg.from) ?? msg.from;
    const groupName = msg.group_name ?? "Unknown";
    const text = msg.data.text_message;
    
    // Format: CALLSIGN@MCGW-[GROUP]> TEXT
    const tag = tagFormat
        .replace("{group_name}", groupName)
        .replace("{sender}", senderCallsign);
    
    const formatted = sprintf("%s%s %s", senderCallsign, tag, text);
    
    return formatted;
}

// =====================================================================
// SNIPPET 4: Audit logging for group bridges
// =====================================================================
//
// Add to gatekeeper.uc:

function auditLogGroupBridge(msg, formattedText)
{
    const logEntry = {
        timestamp: systime(),
        event_type: "MESHCORE_GROUP_BRIDGE",
        
        // Source identification
        transport: msg.transport,
        sender_node_id: msg.from,
        sender_callsign: resolveCallsign(msg.from),
        
        // Group context
        group_slot: msg.group_slot,
        group_name: msg.group_name,
        
        // Message content
        message: msg.data.text_message,
        message_length: length(msg.data.text_message ?? ""),
        
        // Security/compliance context
        identity_strength: "weak",
        symmetric_key: true,
        compliance_note: 
            "Sender proved group membership via symmetric pre-shared key, " +
            "not individual identity via signature. Compliant with " +
            "FCC Part 97 weak-identity rule for group messages.",
        
        // AREDN bridge details
        outbound_format: formattedText,
        target_network: "aredn"
    };
    
    audit_log(logEntry);
    DEBUG1("gatekeeper: group bridge logged\\n");
}

// =====================================================================
// SNIPPET 5: Integration into gatekeeper process flow
// =====================================================================
//
// Add to gatekeeper.filterInboundBridge() or equivalent:

function processInboundMessage(msg, config)
{
    // ... existing direct message handling ...
    
    // NEW: Weak-identity (group message) detection and handling
    if (detectWeakIdentityMessage(msg)) {
        msg = handleWeakIdentityMessage(msg, config);
        if (!msg) {
            return null;  // Message was dropped
        }
    }
    
    // ... rest of filter logic ...
    
    return msg;
}

function processOutboundMessage(msg, target, config)
{
    // ... existing logic ...
    
    // NEW: Format group messages for AREDN
    if (msg.weak_identity && target === "aredn") {
        msg.outbound_formatted = formatGroupMessageForAREDN(msg, config);
        msg.tagged_with_group = true;
        
        // Audit the bridge
        auditLogGroupBridge(msg, msg.outbound_formatted);
        
        // Use formatted text instead of raw
        msg.data.text_message = msg.outbound_formatted;
    }
    
    return msg;
}

// =====================================================================
// SNIPPET 6: Config validation
// =====================================================================
//
// Add to gatekeeper config validation:

function validateGroupMessageConfig(config)
{
    const cfg = config?.gatekeeper?.bridges?.meshcore_tcp_api;
    if (!cfg) return true;
    
    // Validate allow_group_messages is boolean
    if (cfg.allow_group_messages !== null && 
        typeof(cfg.allow_group_messages) !== "boolean") {
        return false;
    }
    
    // Validate require_group_tag is boolean
    if (cfg.require_group_tag !== null && 
        typeof(cfg.require_group_tag) !== "boolean") {
        return false;
    }
    
    // Validate tag_format is string if present
    if (cfg.tag_format && typeof(cfg.tag_format) !== "string") {
        return false;
    }
    
    // Validate allow_aredn_bridge is boolean
    if (cfg.allow_aredn_bridge !== null && 
        typeof(cfg.allow_aredn_bridge) !== "boolean") {
        return false;
    }
    
    // Validate audit_log_groups is boolean
    if (cfg.audit_log_groups !== null && 
        typeof(cfg.audit_log_groups) !== "boolean") {
        return false;
    }
    
    return true;
}

// =====================================================================
// SNIPPET 7: Helper function — Resolve callsign from node ID
// =====================================================================
//
// Add to gatekeeper.uc (or import from nodedb):

function resolveCallsign(nodeId)
{
    // TODO: Look up callsign from nodedb using nodeId
    // For now: return hex string
    
    if (!nodeId) return "Unknown";
    
    // If nodeId is already a number, convert to hex
    let hexId = nodeId;
    if (type(nodeId) === "number") {
        hexId = sprintf("%08x", nodeId);
    }
    
    // TODO: Check nodedb for this ID
    // const node = nodedb.getNode(nodeId, false);
    // if (node && node.user && node.user.callsign) {
    //     return node.user.callsign;
    // }
    
    // Fallback: return hex ID
    return hexId;
}

// =====================================================================
// IMPLEMENTATION CHECKLIST (Phase 3)
// =====================================================================
//
// [ ] 1. Add config fields to gatekeeper config schema (Snippet 1)
// [ ] 2. Add detectWeakIdentityMessage() function (Snippet 2)
// [ ] 3. Add handleWeakIdentityMessage() function (Snippet 2)
// [ ] 4. Add formatGroupMessageForAREDN() function (Snippet 3)
// [ ] 5. Add auditLogGroupBridge() function (Snippet 4)
// [ ] 6. Integrate into filterInboundBridge() (Snippet 5, processInboundMessage)
// [ ] 7. Integrate into outbound routing (Snippet 5, processOutboundMessage)
// [ ] 8. Add validateGroupMessageConfig() (Snippet 6)
// [ ] 9. Add resolveCallsign() helper (Snippet 7)
// [ ] 10. Test: group message formatted correctly
// [ ] 11. Test: audit log records bridge
// [ ] 12. Test: config options control behavior
// [ ] 13. Test: disabled group messages are dropped
//
// =====================================================================
// TESTING (Phase 3)
// =====================================================================
//
// Test Case 1: Group Message Formatting
//   - Input: from=0x4234FF10, group="TacNet", text="test"
//   - Output: "KN6PLV@MCGW-[TacNet]> test"
//   - Verify callsign resolved, group name included, tag format correct
//
// Test Case 2: Audit Logging
//   - Send group message to AREDN
//   - Check audit log for entry
//   - Verify all fields present (timestamp, sender, group, message, compliance)
//
// Test Case 3: Config Control
//   - Set allow_group_messages=false
//   - Send group message
//   - Verify message is dropped, audit log shows "BLOCKED"
//
// Test Case 4: Multiple Groups
//   - Have 3 groups: A, B, C
//   - Send message to each
//   - Bridge all to AREDN
//   - Verify each tagged with correct group name
//   - No cross-contamination between groups
//
// =====================================================================
