#!/usr/bin/env node
'use strict';

const LOCAL_NODE_ID = 0xC0FFEE;
const MAX_PENDING_BACKEND_DRAIN = 4;
const MESHTASTIC_PUBLIC = 'LongFast AQ==';
const MESHCORE_PUBLIC = 'MeshCore izOH6cXN6mrJ5e26oRXNcg==';
const USER_MT = 'TacNet AQ==';
const USER_MC = 'MeshTalk AQ==';

let failures = 0;
let count = 0;

function check(name, got, want) {
    count++;
    if (got === want) {
        console.log(`ok   - ${name}`);
        return;
    }
    failures++;
    console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`);
}

function checkTrue(name, got) {
    check(name, !!got, true);
}

function clone(obj) {
    return JSON.parse(JSON.stringify(obj));
}

function norm(value) {
    if (!value) return null;
    const s = String(value).trim().toUpperCase();
    if (/^[A-Z]{1,2}[0-9][A-Z]{1,3}$/.test(s)) return s;
    const m = s.match(/^([A-Z]{1,2}[0-9][A-Z]{1,3})([-/ ][A-Z0-9 _.-]*)?$/);
    return m ? m[1] : null;
}

function simpleWildcardMatch(text, pattern) {
    if (!text || !pattern) return false;
    const re = '^' + pattern.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$';
    return new RegExp(re).test(text);
}

function matchCallsignPattern(callsign, patterns) {
    callsign = norm(callsign);
    if (!callsign) return false;
    if (!patterns || patterns.length === 0) return true;
    return patterns.map(p => String(p).trim().toUpperCase()).some(p => simpleWildcardMatch(callsign, p));
}

function makeGatekeeper(config) {
    const gk = config.strict_gatekeeper || {};
    const strict = !!gk.enabled;
    const gateway = norm(gk.gateway_callsign || config.callsign);
    const allowed = new Set((gk.allowed_callsigns || config.allowed_callsigns || []).map(norm).filter(Boolean));

    function allowSenderCallsign(callsign) {
        callsign = norm(callsign);
        if (!strict) return callsign;
        if (!gateway || !callsign) return null;
        if (allowed.size > 0 && !allowed.has(callsign)) return null;
        return callsign;
    }

    function findChannelConfig(namekey) {
        const channels = config.channels || [];
        if (Array.isArray(channels)) return channels.find(ch => ch.namekey === namekey) || null;
        return channels[namekey] || null;
    }

    return {
        isEnabled: () => strict,
        enforceChannelAccess(msg, namekey) {
            if (!strict || !msg || !namekey) return msg;
            const chan = findChannelConfig(namekey);
            const acl = chan && chan.access_control;
            if (!acl || !acl.require_callsign) return msg;

            const sender = allowSenderCallsign(msg.data && msg.data.text_from);
            if (!sender) return null;

            const deny = acl.deny_callsigns || acl.deny || [];
            if (deny.length > 0 && matchCallsignPattern(sender, deny)) return null;

            const allow = acl.allowed_callsigns || acl.allow || [];
            if (allow.length > 0 && !matchCallsignPattern(sender, allow)) return null;
            return msg;
        },
        filterInboundBridge(msg) {
            if (!strict || !msg) return msg;
            if (msg.encrypted) return null;
            if (!msg.data || !msg.data.text_message) return null;

            const sender = allowSenderCallsign(msg.data.text_from);
            if (!sender) return null;

            msg.from = LOCAL_NODE_ID;
            msg.originating_callsign = gateway;
            msg.data.text_from = sender;

            if (msg.metadata && msg.metadata.is_group_message && msg.metadata.symmetric_key) {
                const group = msg.group_name || 'UnknownGroup';
                msg.data.text_message = `[${sender}@MCGW-${group} via ${gateway}] ${msg.data.text_message}`;
                msg.metadata.identity_tagged = true;
                msg.metadata.tag_format = 'weak_identity_group';
                return msg;
            }

            msg.data.text_message = `[${sender} via ${gateway}] ${msg.data.text_message}`;
            return msg;
        }
    };
}

function makeRouter({ strict = false, allowed = ['KJ6DZB', 'KN6PLV', 'W2ABC'] } = {}) {
    const localChannels = new Set([MESHTASTIC_PUBLIC, MESHCORE_PUBLIC, USER_MT, USER_MC]);
    const meshcoreSlots = new Map([[2, { namekey: USER_MC, name: 'MeshTalk' }]]);
    const queued = [];
    const gatekeeper = makeGatekeeper({
        callsign: 'KJ6DZB',
        strict_gatekeeper: {
            enabled: strict,
            gateway_callsign: 'KJ6DZB',
            allowed_callsigns: allowed
        },
        channels: [
            {
                namekey: USER_MT,
                access_control: {
                    require_callsign: true,
                    allow: ['KJ6*', 'KN6PLV'],
                    deny: ['KJ6BAD']
                }
            }
        ]
    });

    function isLoRaIngress(msg) {
        return msg && (msg.transport === 'meshtastic' || msg.transport === 'meshcore');
    }

    function isTcpApiIngress(msg) {
        return msg && (
            (msg.transport === 'meshcore' && msg.backend === 'tcp_api') ||
            (msg.transport === 'meshcore' && msg.backend === 'serial_api') ||
            (msg.transport === 'meshtastic' && msg.backend === 'tcp-port-api')
        );
    }

    function isBroadcast(msg) {
        return msg.to === null || msg.to === undefined || msg.to === 0xFFFFFFFF;
    }

    function isDirectForLocalBridgeDevice(msg) {
        if (!isLoRaIngress(msg) || isBroadcast(msg) || (msg.metadata && msg.metadata.is_group_message)) {
            return false;
        }
        if (msg.metadata && msg.metadata.local_direct) {
            return true;
        }
        if (msg.metadata && msg.metadata.direct_identity_verified === true) {
            return false;
        }
        if (isTcpApiIngress(msg) && !msg.channel) {
            return true;
        }
        return msg.to === LOCAL_NODE_ID || (msg.namekey && msg.namekey.startsWith('DirectMessages ') && msg.to === LOCAL_NODE_ID);
    }

    function isJoinedBridgeChannel(msg) {
        if (!isLoRaIngress(msg)) return false;
        if (!msg.namekey && !isBroadcast(msg)) return false;
        return localChannels.has(msg.namekey || MESHTASTIC_PUBLIC);
    }

    function resolveGroupChannel(msg) {
        if (!(msg.metadata && msg.metadata.is_group_message)) return msg;
        const groupChannel = meshcoreSlots.get(msg.group_slot);
        if (!groupChannel) return null;
        msg.namekey = groupChannel.namekey;
        msg.group_name = groupChannel.name;
        return msg;
    }

    function queue(msg) {
        if (!msg) return null;
        msg = resolveGroupChannel(msg);
        if (!msg) return null;
        if (isLoRaIngress(msg) && !isDirectForLocalBridgeDevice(msg) && !isJoinedBridgeChannel(msg)) return null;
        msg = gatekeeper.enforceChannelAccess(msg, msg.namekey);
        if (!msg) return null;
        if (gatekeeper.isEnabled() && isLoRaIngress(msg)) {
            msg = gatekeeper.filterInboundBridge(msg);
            if (!msg) return null;
        }
        queued.push(msg);
        return msg;
    }

    function drainPendingBackend(backend) {
        let n = 0;
        while (backend.pending() > 0 && n < MAX_PENDING_BACKEND_DRAIN) {
            queue(backend.recv());
            n++;
        }
        return n;
    }

    return { queue, queued, drainPendingBackend };
}

function makeTextmessageHarness() {
    const localChannels = new Set([MESHTASTIC_PUBLIC, MESHCORE_PUBLIC, USER_MT, USER_MC]);
    const stored = [];

    function process(msg) {
        if (!msg || !msg.data || !msg.data.text_message) return;

        const localChannel = localChannels.has(msg.namekey);
        if (msg.metadata && msg.metadata.local_direct && String(msg.namekey || '').startsWith('DirectMessages ')) {
            stored.push(msg);
            return;
        }
        if (localChannel && (msg.metadata && msg.metadata.is_group_message)) {
            stored.push(msg);
            return;
        }
        if (localChannel && (msg.to === LOCAL_NODE_ID || msg.to === 0xFFFFFFFF)) {
            stored.push(msg);
            return;
        }
        if (msg.namekey && String(msg.namekey).startsWith('DirectMessages ')) {
            if (msg.to === LOCAL_NODE_ID || msg.from === LOCAL_NODE_ID) {
                stored.push(msg);
            }
        }
    }

    return { process, stored };
}

let id = 1;
function msg(overrides) {
    return Object.assign({
        id: id++,
        transport: 'meshtastic',
        backend: 'udp',
        from: 0x1234,
        to: 0xFFFFFFFF,
        namekey: MESHTASTIC_PUBLIC,
        metadata: {},
        data: { text_from: 'KJ6DZB', text_message: 'hello' }
    }, overrides || {});
}

{
    const r = makeRouter({ strict: false });
    checkTrue('scope: Meshtastic public accepted', r.queue(msg({ namekey: MESHTASTIC_PUBLIC })));
    checkTrue('scope: MeshCore public accepted', r.queue(msg({ transport: 'meshcore', namekey: MESHCORE_PUBLIC })));
    checkTrue('scope: user Meshtastic channel accepted', r.queue(msg({ namekey: USER_MT })));
    checkTrue('scope: mapped MeshCore group slot accepted', r.queue(msg({
        transport: 'meshcore',
        namekey: null,
        group_slot: 2,
        metadata: { is_group_message: true, symmetric_key: true }
    })));
    check('scope: unknown Meshtastic channel dropped', r.queue(msg({ namekey: 'Unknown AQ==' })), null);
    check('scope: unknown MeshCore group slot dropped', r.queue(msg({
        transport: 'meshcore',
        namekey: null,
        group_slot: 7,
        metadata: { is_group_message: true, symmetric_key: true }
    })), null);
    check('scope: UDP direct not to local node dropped', r.queue(msg({
        to: 0x999999,
        namekey: 'DirectMessages AQ=='
    })), null);
    checkTrue('scope: UDP direct to local node accepted', r.queue(msg({
        to: LOCAL_NODE_ID,
        namekey: 'DirectMessages AQ=='
    })));
    checkTrue('scope: Meshtastic TCP local direct accepted', r.queue(msg({
        backend: 'tcp-port-api',
        to: 0x999999,
        namekey: null,
        metadata: { local_direct: true }
    })));
    checkTrue('scope: MeshCore TCP local direct accepted', r.queue(msg({
        transport: 'meshcore',
        backend: 'tcp_api',
        to: 0x999999,
        namekey: null,
        metadata: { local_direct: true }
    })));
    checkTrue('scope: MeshCore USB local direct accepted', r.queue(msg({
        transport: 'meshcore',
        backend: 'serial_api',
        to: 0x999999,
        namekey: null,
        metadata: { local_direct: true }
    })));
    check('scope: MeshCore TCP verified mismatch dropped', r.queue(msg({
        transport: 'meshcore',
        backend: 'tcp_api',
        to: 0x999999,
        namekey: null,
        metadata: { direct_identity_verified: true, local_direct: false }
    })), null);

    const pending = [
        msg({ id: 1001 }), msg({ id: 1002 }), msg({ id: 1003 }),
        msg({ id: 1004 }), msg({ id: 1005 }), msg({ id: 1006 })
    ];
    const backend = { pending: () => pending.length, recv: () => pending.shift() };
    check('scope: bounded pending drain count', r.drainPendingBackend(backend), 4);
    check('scope: pending backend left for later tick', pending.length, 2);
}

{
    const r = makeRouter({ strict: true });
    const accepted = r.queue(msg({ namekey: MESHTASTIC_PUBLIC, data: { text_from: 'KJ6DZB', text_message: 'ok' } }));
    checkTrue('strict: valid callsign sender passes', accepted);
    check('strict: accepted text is annotated', accepted.data.text_message, '[KJ6DZB via KJ6DZB] ok');
    check('strict: invalid sender identity drops', r.queue(msg({ data: { text_from: 'not-a-call', text_message: 'bad' } })), null);
    check('strict: whitelist drops non-member', r.queue(msg({ data: { text_from: 'N5ABC', text_message: 'bad' } })), null);
    check('strict: channel deny list drops', r.queue(msg({ namekey: USER_MT, data: { text_from: 'KJ6BAD', text_message: 'bad' } })), null);
    checkTrue('strict: channel allow list permits', r.queue(msg({ namekey: USER_MT, data: { text_from: 'KN6PLV', text_message: 'ok' } })));
    check('strict: channel allow list drops nonmatching whitelisted callsign', r.queue(msg({ namekey: USER_MT, data: { text_from: 'W2ABC', text_message: 'bad' } })), null);
    const group = r.queue(msg({
        transport: 'meshcore',
        group_slot: 2,
        namekey: null,
        metadata: { is_group_message: true, symmetric_key: true },
        data: { text_from: 'KN6PLV', text_message: 'group' }
    }));
    check('strict: MeshCore group weak-identity tagged', group.data.text_message, '[KN6PLV@MCGW-MeshTalk via KJ6DZB] group');
    check('strict: non-text LoRa payload dropped', r.queue(msg({ data: { text_from: 'KJ6DZB' } })), null);
    check('strict: encrypted bridge packet dropped', r.queue(msg({ encrypted: true })), null);
}

{
    const t = makeTextmessageHarness();
    t.process(msg({
        transport: 'meshcore',
        backend: 'tcp_api',
        namekey: MESHCORE_PUBLIC,
        metadata: { is_group_message: true, group_slot: 7 },
        data: { text_from: 'KJ6DZB', text_message: 'public group' }
    }));
    check('textmessage: meshcore public group stored', t.stored.length, 1);
    check('textmessage: meshcore public group kept on public channel', t.stored[0].namekey, MESHCORE_PUBLIC);

    const t2 = makeTextmessageHarness();
    t2.process(msg({
        transport: 'meshcore',
        backend: 'tcp_api',
        from: 0x12345678,
        namekey: 'DirectMessages 305419896',
        to: 0x999999,
        metadata: { local_direct: true },
        data: { text_from: 'KJ6DZB', text_message: 'direct thread' }
    }));
    check('textmessage: meshcore local direct stored', t2.stored.length, 1);
    check('textmessage: meshcore local direct thread key', t2.stored[0].namekey, 'DirectMessages 305419896');
}

console.log(`\n${count - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
