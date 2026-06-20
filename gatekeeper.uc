import * as node from "node";
import * as nodedb from "nodedb";

const US_CALLSIGN_RE = /^[A-Z]{1,2}[0-9][A-Z]{1,3}$/;

let strict_enabled = false;
let gateway_callsign = null;
let allowed = {};
let allowed_count = 0;

function norm(s)
{
    if (!s) {
        return null;
    }

    s = uc(trim(`${s}`));

    // Accept an exact callsign.
    if (match(s, US_CALLSIGN_RE)) {
        return s;
    }

    // Accept a callsign only when it is the leading identity token, such as
    // "KJ6DZB mobile" or "KJ6DZB-7". Do not accept arbitrary embedded text.
    const m = match(s, /^([A-Z]{1,2}[0-9][A-Z]{1,3})(?:[-/ ][A-Z0-9 _.-]*)?$/);
    return m ? m[1] : null;
}

function loadAllowed(list)
{
    allowed = {};
    allowed_count = 0;
    if (type(list) !== "array") {
        return;
    }
    for (let i = 0; i < length(list); i++) {
        const cs = norm(list[i]);
        if (cs && !allowed[cs]) {
            allowed[cs] = true;
            allowed_count++;
        }
    }
}

export function setup(config)
{
    const gk = config.strict_gatekeeper ?? {};
    strict_enabled = !!gk.enabled;
    gateway_callsign = norm(gk.gateway_callsign ?? config.callsign);
    loadAllowed(gk.allowed_callsigns ?? config.allowed_callsigns);
    if (strict_enabled && !gateway_callsign) {
        DEBUG0("gatekeeper: strict mode enabled but no valid gateway callsign configured\n");
    }
};

export function isEnabled()
{
    return strict_enabled;
};

export function gatewayCallsign()
{
    return gateway_callsign;
};

export function senderCallsignFromNodeId(id)
{
    const info = nodedb.getNode(id, false)?.nodeinfo;
    return norm(info?.short_name) ?? norm(info?.long_name) ?? null;
};

export function senderCallsignFromTextName(name)
{
    return norm(name);
};

export function allowSenderCallsign(callsign)
{
    callsign = norm(callsign);
    if (!strict_enabled) {
        return callsign;
    }
    if (!gateway_callsign) {
        DEBUG0("gatekeeper: drop, no valid gateway callsign\n");
        return null;
    }
    if (!callsign || !match(callsign, US_CALLSIGN_RE)) {
        DEBUG1("gatekeeper: drop, invalid sender callsign\n");
        return null;
    }
    if (allowed_count > 0 && !allowed[callsign]) {
        DEBUG1("gatekeeper: drop, sender callsign not whitelisted\n");
        return null;
    }
    return callsign;
};

export function allowSenderNode(id)
{
    return allowSenderCallsign(senderCallsignFromNodeId(id));
};

export function annotateViaGateway(msg, sender_callsign)
{
    if (!strict_enabled) {
        return msg;
    }
    sender_callsign = allowSenderCallsign(sender_callsign);
    if (!sender_callsign) {
        return null;
    }
    if (!msg?.data?.text_message) {
        DEBUG1("gatekeeper: drop, bridged packet is not a text message\n");
        return null;
    }
    msg.from = node.id();
    msg.originating_callsign = gateway_callsign;
    msg.data.text_from = sender_callsign;
    msg.data.text_message = `[${sender_callsign} via ${gateway_callsign}] ${msg.data.text_message}`;
    return msg;
};

export function filterInboundBridge(msg)
{
    if (!strict_enabled || !msg) {
        return msg;
    }
    if (msg.encrypted) {
        DEBUG0("gatekeeper: drop encrypted bridged packet\n");
        return null;
    }
    if (!msg.data?.text_message) {
        DEBUG1("gatekeeper: drop non-text bridged packet\n");
        return null;
    }
    if (msg.from === node.id() && msg.originating_callsign === gateway_callsign) {
        return msg;
    }
    const sender = msg.data?.text_from ? allowSenderCallsign(msg.data.text_from) : allowSenderNode(msg.from);
    if (!sender) {
        return null;
    }

    // Phase 3: Group message weak-identity tagging for AREDN bridge
    if (msg.metadata?.is_group_message && msg.metadata?.symmetric_key) {
        return annotateGroupViaGateway(msg, sender);
    }

    return annotateViaGateway(msg, sender);
};

// Phase 3: Format group messages with weak-identity tag for Part 97 compliance
// Group messages use symmetric pre-shared keys — sender proves membership,
// not individual identity. Tag outbound format: [CALL@MCGW-GroupName via GW]
export function annotateGroupViaGateway(msg, sender_callsign)
{
    if (!strict_enabled) {
        return msg;
    }
    sender_callsign = allowSenderCallsign(sender_callsign);
    if (!sender_callsign) {
        return null;
    }
    if (!msg?.data?.text_message) {
        DEBUG1("gatekeeper: drop, group bridged packet is not a text message\n");
        return null;
    }

    const groupName = msg.group_name ?? "UnknownGroup";

    msg.from = node.id();
    msg.originating_callsign = gateway_callsign;
    msg.data.text_from = sender_callsign;
    msg.data.text_message = `[${sender_callsign}@MCGW-${groupName} via ${gateway_callsign}] ${msg.data.text_message}`;
    msg.metadata.identity_tagged = true;
    msg.metadata.tag_format = "weak_identity_group";

    DEBUG1("gatekeeper: group bridge tagged: %s@MCGW-%s via %s\n",
           sender_callsign, groupName, gateway_callsign);
    return msg;
};

// NEW (Phase 4): Per-channel callsign access control
// Enforce channel-level ACLs (allowlist/denylist with wildcard patterns)

function simpleWildcardMatch(text, pattern)
{
    // Simple glob-style matching: * matches any characters
    // "K*" matches K0ABC, K6DZB, etc.
    // "*DZB" matches K6DZB, W2DZB, etc.
    // "K6DZB" matches exactly K6DZB
    
    if (!text || !pattern) return false;
    
    // Exact match
    if (text === pattern) return true;
    
    // Handle simple wildcards (not full regex)
    let text_idx = 0;
    let pattern_idx = 0;
    
    while (pattern_idx < length(pattern)) {
        if (ord(pattern, pattern_idx) === 42) {  // * character
            // Wildcard: skip to next pattern char or end
            pattern_idx++;
            if (pattern_idx >= length(pattern)) {
                return true;  // * at end matches rest of text
            }
            
            // Find next char that matches pattern[pattern_idx]
            const nextPatternChar = substr(pattern, pattern_idx, 1);
            while (text_idx < length(text)) {
                if (substr(text, text_idx, 1) === nextPatternChar) {
                    break;
                }
                text_idx++;
            }
            if (text_idx >= length(text)) {
                return false;  // Pattern char not found
            }
            text_idx++;
            pattern_idx++;
        } else {
            // Regular character: must match exactly
            if (text_idx >= length(text)) {
                return false;
            }
            if (substr(text, text_idx, 1) !== substr(pattern, pattern_idx, 1)) {
                return false;
            }
            text_idx++;
            pattern_idx++;
        }
    }
    
    // All pattern consumed; text must also be consumed
    return text_idx === length(text);
}

function matchCallsignPattern(callsign, patterns)
{
    // Check if callsign matches any pattern in the list
    if (!patterns || length(patterns) === 0) {
        return true;  // No restrictions
    }
    
    for (let pattern of patterns) {
        if (simpleWildcardMatch(callsign, pattern)) {
            return true;
        }
    }
    return false;
}

export function enforceChannelAccess(msg, namekey, config)
{
    // Enforce channel-level callsign ACLs
    // If channel has access_control config, verify sender callsign
    
    if (!strict_enabled || !msg || !namekey || !config) {
        return msg;  // Gatekeeper disabled or missing config
    }
    
    // Get channel-specific ACL config
    const chan_config = config?.channels?.[namekey];
    const acl = chan_config?.access_control;
    
    if (!acl || !acl.require_callsign) {
        return msg;  // No ACL configured for this channel
    }
    
    // Extract sender callsign
    const sender_callsign = msg.data?.text_from ?? senderCallsignFromNodeId(msg.from);
    
    if (!sender_callsign) {
        DEBUG0("gatekeeper: channel access DENIED (no callsign) channel=%s from=%08x\n",
               namekey, msg.from);
        return null;  // Drop message
    }
    
    // Check explicit deny list
    if (acl.deny_callsigns && length(acl.deny_callsigns) > 0) {
        if (matchCallsignPattern(sender_callsign, acl.deny_callsigns)) {
            DEBUG0("gatekeeper: channel access DENIED (deny list) channel=%s callsign=%s\n",
                   namekey, sender_callsign);
            return null;  // Drop message
        }
    }
    
    // Check allow list
    if (acl.allowed_callsigns && length(acl.allowed_callsigns) > 0) {
        if (!matchCallsignPattern(sender_callsign, acl.allowed_callsigns)) {
            DEBUG0("gatekeeper: channel access DENIED (not in allow list) channel=%s callsign=%s\n",
                   namekey, sender_callsign);
            return null;  // Drop message
        }
    }
    
    // Access granted
    DEBUG1("gatekeeper: channel access ALLOWED channel=%s callsign=%s\n",
           namekey, sender_callsign);
    return msg;
}

export function tick()
{
};

export function process(msg)
{
};
