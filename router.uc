// AREDN ucode: use require() instead of ES6 import for compatibility
const meshtastic = require("meshtastic_backend");
const meshcore = require("meshcore_backend");
const meship = require("meship");
const aprs = require("aprs");
const node = require("node");
const nodedb = require("nodedb");
const socket = require("socket");
const timers = require("timers");
const channel = require("channel");
const websocket = require("websocket");

const MAX_RECENT = 128;
const recent = [];
const apps = [];
const q = [];
let gatekeeper = null;

function setGatekeeper(gk)
{
    gatekeeper = gk;
};

// NEW (Phase 1): Register temporary group channel for testing
// Before Phase 2 implements auto-discovery, this allows manual setup
// of group slot -> channel mappings for testing.
// Usage: router.registerGroupChannel(0, group_channel_object)
function registerGroupChannel(slot, channelObj)
{
    if (slot === null || slot === undefined || slot < 0 || slot > 7) {
        return false;
    }
    if (!channelObj || !channelObj.namekey) {
        return false;
    }
    const result = channel.setMeshcoreSlotChannel(slot, channelObj);
    DEBUG0("router: registered group slot %d -> %s\n", slot, channelObj.namekey);
    return result;
};

function registerApp(app)
{
    push(apps, app);
};

function process()
{
    while (length(q) > 0) {
        const msg = shift(q);

        if (node.fromMe(msg)) {
            DEBUG1("%.2J\n", msg);
        }
        else {
            DEBUG2("%.2J\n", msg);
        }

        // Give each app a chance at the message
        for (let i = 0; i < length(apps); i++) {
            apps[i].process(msg);
        }

        // Forward the message if it's not just to me. We never forward encrypted traffic.
        if (!node.toMe(msg) && !msg.encrypted) {
            if (!node.fromMe(msg)) {
                if (!node.canForward()) {
                    continue;
                }
                msg.hop_limit--;
                if (msg.hop_limit < 0) {
                    continue;
                }
            }

            // Determine which interfaces we can route the packet out on.
            // msg.transport == the way the message entered the system, "native" indicating it originated natively and didn't
            // arrive via a bridge.
            let toip = false;
            let tomeshtastic = false;
            let tomeshcore = false;
            // If we know where the msg goes, it goes vi IP
            if (platform.getTargetById(msg.to)) {
                toip = true;
                msg.hop_limit = 0;
            }
            // Otherwise if it's from me or originated natively, then it goes everywhere. If we know the
            // target network we can avoiding retransmitting it unnecessarily.
            else if (msg.transport === "native") {
                const tonodeinfo = node.isBroadcast(msg) ? null : nodedb.getNode(msg.to, false)?.nodeinfo;
                // MeshIP bridge traffic should never be forwarded by a receiver and is only ever for the direct recipient.
                if (meship.isBridge()) {
                    // We don't forward meshtasticore preset traffic across an IP bridge, we keep it local.
                    if (!channel.isMeshcorePreset(msg.namekey) && !channel.isMeshtasticPreset(msg.namekey)) {
                        toip = true;
                        msg.hop_limit = 0;
                    }
                }
                else if (node.fromMe(msg) || tonodeinfo?.platform === "native") {
                    toip = true;
                }
                if (!channel.isAREDNOnly(msg.namekey)) {
                    // Forward traffic to meshtastic if it's not a preset channel for another mesh
                    if (meshtastic.enabled && !channel.isMeshcorePreset(msg.namekey)) {
                        if (!tonodeinfo || tonodeinfo.platform === "meshtastic") {
                            tomeshtastic = true;
                        }
                    }
                    // Forward traffic to meshcore if it's not a preset channel for another mesh
                    if (meshcore.enabled && !channel.isMeshtasticPreset(msg.namekey)) {
                        if (!tonodeinfo || tonodeinfo.platform === "meshcore") {
                            tomeshcore = true;
                        }
                    }
                }
            }
            // Incoming meshtasticore bridged traffic can only route via IP
            // Note that we dont sent traffic from one bridge to another (no meshtastic <-> meshcore bridging) at the moment.
            else {
                toip = true;
                msg.hop_limit = 0;
            }

            if (toip) {
                try {
                    DEBUG1("Send MeshIP: %.2J\n", msg);
                    // Include forwarding nodes when sending the message if the hop_limit allows it
                    meship.send(msg.to, msg, msg.hop_limit > 0);
                }
                catch (e) {
                    DEBUG0("meship recv: %s\n", e.stacktrace);
                }
            }
            if (tomeshcore) {
                try {
                    DEBUG1("Send Meshcore: %.2J\n", msg);
                    meshcore.send(msg);
                }
                catch (e) {
                    DEBUG0("meshcore recv: %s\n", e.stacktrace);
                }
            }
            // Meshtastic modifies the message so much come last
            if (tomeshtastic) {
                try {
                    DEBUG1("Send Meshtastic: %.2J\n", msg);
                    meshtastic.send(msg);
                }
                catch (e) {
                    DEBUG0("meshtastic recv: %s\n", e.stacktrace);
                }
            }
        }
    }
};

function queueId(id)
{
    // Remember messages we queued for a little while and don't queue them again.
    if (index(recent, id) === -1) {
        push(recent, id);
        if (length(recent) > MAX_RECENT) {
            shift(recent);
        }
        return true;
    }
    return false;
};

// NEW (Phase 1): Resolve group message channel by slot index
// Group messages from MeshCore TCP API have group_slot field (0-7)
// which identifies the memory slot. Map this to a Crow channel.
function resolveGroupChannel(msg)
{
    if (!msg.metadata?.is_group_message) {
        return msg;  // Not a group message
    }
    
    const slot = msg.group_slot;
    if (slot === null || slot === undefined) {
        DEBUG0("router: group message missing group_slot, dropping\n");
        return null;
    }
    
    // Look up which channel is mapped to this slot
    const groupChannel = channel.getChannelByMeshcoreSlot(slot);
    
    if (!groupChannel) {
        DEBUG0("router: group message slot %d not mapped to any channel, dropping\n", slot);
        // TODO (Phase 2): Could queue for later once discovery runs
        return null;
    }
    
    // Set the channel for routing
    msg.namekey = groupChannel.namekey;
    msg.group_name = groupChannel.name;
    
    DEBUG1("router: routed group message (slot %d) to channel %s\n", 
           slot, groupChannel.namekey);
    return msg;
};

// NEW (Phase 4): Enforce channel-level access control
// Verify sender has valid callsign and meets per-channel ACLs
function enforceChannelAccess(msg)
{
    if (!gatekeeper || !gatekeeper.isEnabled()) {
        return msg;  // Gatekeeper not enabled
    }
    
    if (!msg || !msg.namekey) {
        return msg;  // No channel specified
    }
    
    // Call gatekeeper's channel access enforcement
    const result = gatekeeper.enforceChannelAccess(msg, msg.namekey, global.config);
    return result;  // null if access denied, msg if allowed
};

function queue(msg)
{
    if (!msg) {
        return;
    }

    // NEW (Phase 1): Resolve group message channel
    if (msg.metadata?.is_group_message) {
        msg = resolveGroupChannel(msg);
        if (!msg) {
            return;  // Group message couldn't be routed
        }
    }

    // NEW (Phase 4): Enforce channel-level access control
    msg = enforceChannelAccess(msg);
    if (!msg) {
        return;  // Access denied by per-channel ACL
    }

    if (gatekeeper?.isEnabled() && (msg.transport === "meshtastic" || msg.transport === "meshcore")) {
        msg = gatekeeper.filterInboundBridge(msg);
        if (!msg) {
            return;
        }
    }

    if (queueId(msg.id)) {
        push(q, msg);
    }
};


function tick()
{
    for (let i = 0; i < length(apps); i++) {
        apps[i].tick();
    }
    process();
    const sockets = [];
    const us = meship.handle();
    if (us) {
        push(sockets, [ us, socket.POLLIN, "meship" ]);
    }
    const ms = meshtastic.handle();
    if (ms) {
        push(sockets, [ ms, socket.POLLIN, "meshtastic" ]);
    }
    const mc = meshcore.handle();
    if (mc) {
        push(sockets, [ mc, socket.POLLIN, "meshcore" ]);
    }
    const as = aprs.handle();
    if (as) {
        if (type(as) === "array") {
            for (let i = 0; i < length(as); i++) {
                push(sockets, [ as[i].socket, socket.POLLIN|socket.POLLRDHUP, `aprs:${as[i].name}` ]);
            }
        }
        else {
            push(sockets, [ as, socket.POLLIN|socket.POLLRDHUP, "aprs" ]);
        }
    }
    const ph = platform.handle();
    if (ph) {
        push(sockets, [ ph, socket.POLLIN|socket.POLLRDHUP, "platform" ]);
    }
    const ws = websocket.handles();
    if (ws) {
        for (let i = 0; i < length(ws); i++) {
            push(sockets, [ ws[i], socket.POLLIN|socket.POLLRDHUP, "websocket" ]);
        }
    }
    const v = socket.poll(timers.minTimeout(60) * 1000, ...sockets);
    for (let i = 0; i < length(v); i++) {
        if (v[i] && v[i][1]) {
            const evtype = v[i][2];
            switch (evtype) {
                case "websocket":
                {
                    const msgs = websocket.recv(v[i][0]);
                    for (let i = 0; i < length(msgs); i++) {
                        const msg = msgs[i];
                        if (msg.text) {
                            const j = json(msg.text);
                            j.socket = msg.socket;
                            event.queue(j);
                        }
                        else if (msg.binary) {
                            event.queue({ cmd: "upload", binary: msg.binary, socket: msg.socket });
                        }
                    }
                    break;
                }
                case "meship":
                    try {
                        queue(meship.recv());
                    }
                    catch (e) {
                        DEBUG0("meship recv: %s\n%s\n", e, e.stacktrace);
                    }
                    break;
                case "meshtastic":
                    try {
                        queue(meshtastic.recv());
                    }
                    catch (e)
                    {
                        DEBUG0("meshtastic recv: %s\n%s\n", e, e.stacktrace);
                    }
                    break;
                case "meshcore":
                    try {
                        queue(meshcore.recv());
                    }
                    catch (e) {
                        DEBUG0("meshcore recv: %s\n%s\n", e, e.stacktrace);
                    }
                    break;
                case "aprs":
                    try {
                        queue(aprs.recv(null));
                    }
                    catch (e) {
                        DEBUG0("aprs recv: %s\n%s\n", e, e.stacktrace);
                    }
                    break;
                default:
                    if (substr(evtype, 0, 5) === "aprs:") {
                        try {
                            queue(aprs.recv(substr(evtype, 5)));
                        }
                        catch (e) {
                            DEBUG0("aprs recv: %s\n%s\n", e, e.stacktrace);
                        }
                    }
                    break;
                case "platform":
                {
                    platform.handleChanges();
                    break;
                }
            }
        }
    }

    meship.tick();
    meshtastic.tick();
    meshcore.tick();
    aprs.tick();
    timers.process();
};
