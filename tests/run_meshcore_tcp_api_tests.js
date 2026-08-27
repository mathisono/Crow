// Node-runnable mirror of tests/test_meshcore_tcp_api.uc.
// Exercises stock MeshCore TCP / Serial-WiFi framing:
//   Radio -> client: '>' + uint16le(length) + payload
//   Client -> radio: '<' + uint16le(length) + payload

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

const FRAME_FROM_RADIO = 0x3E;
const FRAME_TO_RADIO = 0x3C;
const HEADER_BYTES = 3;
const SMART_MAX_PAYLOAD = 256;
const RESYNC_BUFFER_CAP = 4096;

const PUSH_CODE_MSG_WAITING = 0x83;
const CMD_SYNC_NEXT_MESSAGE = 0x0A;
const CMD_ADD_UPDATE_CONTACT = 0x09;
const CMD_SET_CHANNEL = 0x20;
const CMD_SEND_ANON_REQ = 0x39;
const RESP_DIRECT_MSG_RECV = 0x07;
const RESP_CHANNEL_MSG_RECV = 0x08;
const RESP_DIRECT_MSG_RECV_V3 = 0x10;
const RESP_CHANNEL_MSG_RECV_V3 = 0x11;
const RESP_CHANNEL_INFO = 0x12;
const RESP_CHANNEL_DATA_RECV = 0x1B;
const MAX_CHANNEL_DATA_LENGTH = 163;
const CMD_ENCRYPTED_DM = 0x90;
const CMD_ENCRYPTED_BIN = 0x91;
const CMD_UNKNOWN = 0x77;

const PART97_BLOCKED_COMMANDS = new Set([CMD_ENCRYPTED_DM, CMD_ENCRYPTED_BIN]);
let meshcoreSelfId = null;
const directIdentityStats = { verified: 0, mismatch: 0, unverified: 0 };
const channelDataStats = { received: 0, routed: 0, unrouted: 0 };
const channelDataTextTypes = new Set();
const localGroupChannels = new Set();
const discoveredGroupChannels = new Map();
const mappedGroupChannels = new Map();
let groupReceiveUnverified = 0;

function isDirect(code) { return code === RESP_DIRECT_MSG_RECV || code === RESP_DIRECT_MSG_RECV_V3; }
function isGroup(code) { return code === RESP_CHANNEL_MSG_RECV || code === RESP_CHANNEL_MSG_RECV_V3; }
function isMessage(code) { return isDirect(code) || isGroup(code); }
function sameU32(a, b) { return (a >>> 0) === (b >>> 0); }

class SmartAccumulator {
    constructor(gatekeeper) {
        this.gatekeeper = gatekeeper;
        this.buf = Buffer.alloc(0);
        this.pendingSkip = 0;
        this.responses = [];
        this.commands = [];
        this.stats = {
            frames_in: 0,
            commands_sent: 0,
            message_waiting: 0,
            responses_cached: 0,
            early_drop_oversize: 0,
            early_drop_encrypted: 0,
            early_drop_unknown_cmd: 0,
            early_drop_malformed_text: 0,
            channel_data_received: 0,
            channel_data_routed: 0,
            channel_data_unrouted: 0,
            resync_skips: 0
        };
    }

    _advance(hdrBytes, payloadBytes) {
        const total = hdrBytes + payloadBytes;
        if (this.buf.length >= total) {
            this.buf = this.buf.subarray(total);
            return;
        }
        this.pendingSkip = total - this.buf.length;
        this.buf = Buffer.alloc(0);
    }

    _sendCommand(cmd, payload = Buffer.alloc(0)) {
        this.commands.push(buildCommand(cmd, payload));
        this.stats.commands_sent++;
    }

    takeResponse(cmd) {
        const idx = this.responses.findIndex(r => r.cmd === cmd);
        if (idx < 0) return null;
        return this.responses.splice(idx, 1)[0];
    }

    inject(data) {
        const frames = [];
        let chunk = Buffer.isBuffer(data) ? data : Buffer.from(data, 'binary');

        if (this.pendingSkip > 0 && chunk.length > 0) {
            const drop = Math.min(this.pendingSkip, chunk.length);
            chunk = chunk.subarray(drop);
            this.pendingSkip -= drop;
            if (this.pendingSkip > 0) return frames;
        }

        if (chunk.length > 0) this.buf = Buffer.concat([this.buf, chunk]);
        const strictOn = this.gatekeeper && this.gatekeeper.isEnabled();

        for (;;) {
            const blen = this.buf.length;
            if (blen === 0) return frames;

            if (this.buf[0] !== FRAME_FROM_RADIO) {
                const start = this.buf.indexOf(FRAME_FROM_RADIO, 1);
                if (start < 0) {
                    if (blen > RESYNC_BUFFER_CAP) {
                        this.stats.resync_skips++;
                        this.buf = Buffer.alloc(0);
                    }
                    return frames;
                }
                this.stats.resync_skips++;
                this.buf = this.buf.subarray(start);
                continue;
            }

            if (blen < HEADER_BYTES) return frames;
            const plen = this.buf.readUInt16LE(1);

            if (plen < 1) {
                this.stats.early_drop_malformed_text++;
                this.buf = this.buf.subarray(HEADER_BYTES);
                continue;
            }
            if (plen > SMART_MAX_PAYLOAD) {
                this.stats.early_drop_oversize++;
                this._advance(HEADER_BYTES, plen);
                continue;
            }
            if (blen < HEADER_BYTES + plen) return frames;

            const framePayload = this.buf.subarray(HEADER_BYTES, HEADER_BYTES + plen);
            this.buf = this.buf.subarray(HEADER_BYTES + plen);
            const code = framePayload[0];
            const payload = framePayload.subarray(1);
            this.stats.frames_in++;

            if (code === PUSH_CODE_MSG_WAITING) {
                this.stats.message_waiting++;
                this._sendCommand(CMD_SYNC_NEXT_MESSAGE);
                continue;
            }
            if (strictOn && PART97_BLOCKED_COMMANDS.has(code)) {
                this.stats.early_drop_encrypted++;
                continue;
            }
            if (isMessage(code)) {
                if (!validTextPayload(code, payload)) {
                    this.stats.early_drop_malformed_text++;
                    continue;
                }
                frames.push({ cmd: code, payload });
                continue;
            }
            if (code === RESP_CHANNEL_DATA_RECV) {
                if (!validChannelDataPayload(payload)) this.stats.early_drop_malformed_text++;
                else frames.push({ cmd: code, payload });
                continue;
            }
            if (code === 0x82 || code === 0x84 || code === 0x8A || code === 0x88 ||
                code === 0x89 || code === 0x8B || code === 0x8C || code === 0x8E || code === 0x90) {
                continue;
            }
            if (code === RESP_CHANNEL_INFO) {
                this.stats.responses_cached++;
                this.responses.push({ cmd: code, payload: framePayload });
                continue;
            }
            this.stats.early_drop_unknown_cmd++;
        }
    }
}

function validTextPayload(code, payload) {
    if (isDirect(code)) {
        if (payload.length < 9) return false;
        return 9 + payload[8] <= payload.length;
    }
    if (isGroup(code)) return payload.length >= 5;
    return false;
}

function validChannelDataPayload(payload) {
    if (payload.length < 9) return false;
    const slot = payload[3];
    const dataLength = payload[7];
    return slot <= 7 && dataLength <= MAX_CHANNEL_DATA_LENGTH && 8 + dataLength <= payload.length;
}

function channelDataPayload(slot, dataType, text, snr = 0) {
    const textBytes = Buffer.from(text, 'utf8');
    return Buffer.concat([
        Buffer.from([snr & 0xff, 0, 0, slot & 0xff, 0, dataType & 0xff, (dataType >> 8) & 0xff, textBytes.length]),
        textBytes
    ]);
}

function setChannelCommand(slot, name, secret) {
    const padded = Buffer.concat([Buffer.from(name, 'utf8'), Buffer.alloc(32 - Buffer.byteLength(name))]);
    return buildCommand(CMD_SET_CHANNEL, Buffer.concat([Buffer.from([slot]), padded, secret]));
}

function roomLoginCommand(publicKey, syncSince, password) {
    const stamp = Buffer.alloc(8);
    stamp.writeUInt32LE(Math.floor(Date.now() / 1000), 0);
    stamp.writeUInt32LE(syncSince >>> 0, 4);
    return buildCommand(CMD_SEND_ANON_REQ, Buffer.concat([publicKey, stamp, Buffer.from(password)]));
}

function roomContactCommand(publicKey, name) {
    return buildCommand(CMD_ADD_UPDATE_CONTACT, Buffer.concat([
        publicKey, Buffer.from([3, 0, 0xFF]), Buffer.alloc(64),
        Buffer.from(name, 'utf8'), Buffer.alloc(32 - Buffer.byteLength(name)), Buffer.alloc(4)
    ]));
}

function decodeTextFrame(cmd, payload) {
    if (cmd === RESP_CHANNEL_DATA_RECV) {
        if (!validChannelDataPayload(payload)) return null;
        channelDataStats.received++;
        const slot = payload[3];
        const dataType = payload.readUInt16LE(5);
        if (!channelDataTextTypes.has(dataType)) {
            channelDataStats.unrouted++;
            return null;
        }
        const text = payload.subarray(8, 8 + payload[7]).toString('utf8').replace(/\0+$/, '');
        const namekey = mappedGroupChannels.get(slot);
        if (!text.length || !namekey || !localGroupChannels.has(namekey) || discoveredGroupChannels.get(slot) !== namekey) {
            channelDataStats.unrouted++;
            return null;
        }
        channelDataStats.routed++;
        return {
            group_slot: slot,
            channel_index: slot,
            namekey,
            transport: 'meshcore',
            backend: 'tcp_api',
            data: { text_message: text },
            metadata: {
                is_group_message: true,
                channel_data: true,
                channel_data_type: dataType
            }
        };
    }
    if (isDirect(cmd)) {
        const fromId = payload.readUInt32LE(0);
        const toId = payload.readUInt32LE(4);
        const tlen = payload[8];
        const text = payload.subarray(9, 9 + tlen).toString('utf8').replace(/\0+$/, '');
        if (!text.length) return null;
        const verified = meshcoreSelfId !== null && meshcoreSelfId !== undefined;
        const localDirect = verified ? sameU32(toId, meshcoreSelfId) : true;
        if (verified) {
            directIdentityStats.verified++;
            if (!localDirect) directIdentityStats.mismatch++;
        } else {
            directIdentityStats.unverified++;
        }
        return {
            from: fromId,
            to: toId,
            transport: 'meshcore',
            backend: 'tcp_api',
            data: { text_message: text },
            metadata: {
                is_group_message: false,
                local_direct: localDirect,
                direct_identity_verified: verified,
                meshcore_response_code: cmd
            }
        };
    }
    if (isGroup(cmd)) {
        const fromId = payload.readUInt32LE(0);
        const slot = payload[4];
        const text = payload.subarray(5).toString('utf8').replace(/\0+$/, '');
        if (!text.length) return null;
        const namekey = mappedGroupChannels.get(slot);
        if (!namekey || !localGroupChannels.has(namekey) || discoveredGroupChannels.get(slot) !== namekey) {
            groupReceiveUnverified++;
            return null;
        }
        return {
            from: fromId,
            group_slot: slot,
            namekey,
            transport: 'meshcore',
            backend: 'tcp_api',
            data: { text_message: text },
            metadata: { is_group_message: true, group_slot: slot, meshcore_response_code: cmd }
        };
    }
    return null;
}

function configureGroupChannel(slot, namekey) {
    discoveredGroupChannels.set(slot, namekey);
    if (localGroupChannels.has(namekey)) {
        mappedGroupChannels.set(slot, namekey);
        return true;
    }
    mappedGroupChannels.delete(slot);
    return false;
}

function remapDiscoveredGroupChannels() {
    for (const [slot, namekey] of discoveredGroupChannels) {
        if (localGroupChannels.has(namekey)) mappedGroupChannels.set(slot, namekey);
        else mappedGroupChannels.delete(slot);
    }
}

function clearGroupChannels() {
    localGroupChannels.clear();
    discoveredGroupChannels.clear();
    mappedGroupChannels.clear();
    groupReceiveUnverified = 0;
}

function channelSendAllowed(slot, namekey) {
    return !!namekey && localGroupChannels.has(namekey) &&
        discoveredGroupChannels.get(slot) === namekey &&
        mappedGroupChannels.get(slot) === namekey;
}

function buildRadioFrame(cmd, payload = Buffer.alloc(0)) {
    const p = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || '', 'binary');
    const fp = Buffer.concat([Buffer.from([cmd & 0xFF]), p]);
    return Buffer.concat([Buffer.from([FRAME_FROM_RADIO, fp.length & 0xFF, (fp.length >> 8) & 0xFF]), fp]);
}

function buildCommand(cmd, payload = Buffer.alloc(0)) {
    const p = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || '', 'binary');
    const fp = Buffer.concat([Buffer.from([cmd & 0xFF]), p]);
    return Buffer.concat([Buffer.from([FRAME_TO_RADIO, fp.length & 0xFF, (fp.length >> 8) & 0xFF]), fp]);
}

function appStartPayload(profile) {
    return profile === 'meshcore_cli'
        ? Buffer.from([0x03, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, ...Buffer.from('Crow')])
        : Buffer.from([0, 0, 0, 0, 0, 0, 0, ...Buffer.from('Crow')]);
}

function buildChannelSend(slot, text) {
    const t = Buffer.from(text).subarray(0, 200);
    return buildCommand(0x03, Buffer.concat([Buffer.from([0x00, slot]), Buffer.alloc(4), t]));
}

function buildDirectSend(prefix, text, attempt) {
    const t = Buffer.from(text).subarray(0, 200);
    return buildCommand(0x02, Buffer.concat([Buffer.from([0x00, attempt & 0xff]), Buffer.alloc(4), Buffer.from(prefix), t]));
}

function u32le(n) { return Buffer.from([n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF]); }
function directPayload(from, to, text) { const t = Buffer.from(text); return Buffer.concat([u32le(from), u32le(to), Buffer.from([t.length]), t]); }
function groupPayload(from, slot, text) { return Buffer.concat([u32le(from), Buffer.from([slot]), Buffer.from(text)]); }

let failures = 0, count = 0;
function check(name, got, want) {
    count++;
    const same = got === want || (Buffer.isBuffer(got) && Buffer.isBuffer(want) && got.equals(want));
    if (same) console.log(`ok   - ${name}`);
    else { failures++; console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`); }
}
function checkTrue(name, got) { check(name, !!got, true); }

const STRICT_ON  = { isEnabled: () => true };
const STRICT_OFF = { isEnabled: () => false };

{
    const a = new SmartAccumulator(STRICT_ON);
    const payload = directPayload(0x11223344, 0x55667788, 'hello mesh');
    const f = a.inject(buildRadioFrame(RESP_DIRECT_MSG_RECV, payload));
    check('single frame: count', f.length, 1);
    check('single frame: cmd', f[0]?.cmd, RESP_DIRECT_MSG_RECV);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    const frame = buildRadioFrame(RESP_CHANNEL_MSG_RECV, groupPayload(0xDEADBEEF, 3, 'fragment me'));
    check('fragmented read 1', a.inject(frame.subarray(0, 2)).length, 0);
    check('fragmented read 2', a.inject(frame.subarray(2, 7)).length, 0);
    check('fragmented read 3', a.inject(frame.subarray(7)).length, 1);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    a.inject(Buffer.from([FRAME_FROM_RADIO, 0x60, 0xEA]));
    check('oversize rejected', a.stats.early_drop_oversize, 1);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    a.inject(Buffer.from([FRAME_FROM_RADIO, 0x01, 0x01]));
    check('boundary 257 rejected', a.stats.early_drop_oversize, 1);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    a.inject(buildRadioFrame(CMD_ENCRYPTED_DM, Buffer.alloc(16)));
    check('encrypted strict drop', a.stats.early_drop_encrypted, 1);
}
{
    const a = new SmartAccumulator(STRICT_OFF);
    a.inject(buildRadioFrame(CMD_ENCRYPTED_DM, Buffer.alloc(16)));
    check('encrypted strict-off ignored as known non-message', a.stats.early_drop_unknown_cmd, 0);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    a.inject(buildRadioFrame(PUSH_CODE_MSG_WAITING));
    check('message waiting stat', a.stats.message_waiting, 1);
    check('message waiting sends sync', a.commands[0]?.[3], CMD_SYNC_NEXT_MESSAGE);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    const frame = buildRadioFrame(RESP_DIRECT_MSG_RECV, directPayload(1, 2, 'after garbage'));
    check('resync after garbage', a.inject(Buffer.concat([Buffer.from([0, 1, 2]), frame])).length, 1);
    checkTrue('resync stat', a.stats.resync_skips >= 1);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    const buf = Buffer.concat([
        buildRadioFrame(RESP_DIRECT_MSG_RECV, directPayload(1, 2, 'one')),
        buildRadioFrame(RESP_DIRECT_MSG_RECV, directPayload(3, 4, 'two'))
    ]);
    check('back-to-back frames', a.inject(buf).length, 2);
}
{
    const a = new SmartAccumulator(STRICT_ON);
    const evil = Buffer.concat([u32le(1), u32le(2), Buffer.from([99]), Buffer.from('abc')]);
    check('malformed direct dropped', a.inject(buildRadioFrame(RESP_DIRECT_MSG_RECV, evil)).length, 0);
    check('malformed stat', a.stats.early_drop_malformed_text, 1);
}
{
    const msg = decodeTextFrame(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0, 'hi'));
    check('decode direct text', msg?.data?.text_message, 'hi');
    check('decode direct group flag', msg?.metadata?.is_group_message, false);
    check('decode direct unverified accepted', msg?.metadata?.local_direct, true);
    check('decode direct identity unverified', msg?.metadata?.direct_identity_verified, false);
    check('decode direct unverified stat', directIdentityStats.unverified, 1);
}
{
    meshcoreSelfId = 0x55667788;
    const match = decodeTextFrame(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0x55667788, 'for me'));
    const mismatch = decodeTextFrame(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0x11111111, 'not me'));
    check('decode direct verified match accepted', match?.metadata?.local_direct, true);
    check('decode direct verified match marked', match?.metadata?.direct_identity_verified, true);
    check('decode direct verified mismatch not local', mismatch?.metadata?.local_direct, false);
    check('decode direct verified mismatch marked', mismatch?.metadata?.direct_identity_verified, true);
    check('decode direct verified stat', directIdentityStats.verified, 2);
    check('decode direct mismatch stat', directIdentityStats.mismatch, 1);
    meshcoreSelfId = null;
}
{
    meshcoreSelfId = 0xF5667788;
    const msg = decodeTextFrame(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0xF5667788, 'high id'));
    check('decode direct high-bit id accepted', msg?.metadata?.local_direct, true);
    check('decode direct high-bit id to', msg?.to, 0xF5667788);
    check('decode direct verified stat high-bit', directIdentityStats.verified, 3);
    meshcoreSelfId = null;
}
{
    meshcoreSelfId = 0;
    const msg = decodeTextFrame(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0, 'zero id'));
    check('decode direct zero self id accepted', msg?.metadata?.local_direct, true);
    check('decode direct zero self id verified', msg?.metadata?.direct_identity_verified, true);
    check('decode direct verified stat zero id', directIdentityStats.verified, 4);
    meshcoreSelfId = null;
}
{
    clearGroupChannels();
    localGroupChannels.add('TacNet AQ==');
    check('group setup: exact radio/Crow channel mapped', configureGroupChannel(5, 'TacNet AQ=='), true);
    const msg = decodeTextFrame(RESP_CHANNEL_MSG_RECV, groupPayload(0xDEADBEEF, 5, 'yo'));
    check('decode group text', msg?.data?.text_message, 'yo');
    check('decode group slot', msg?.group_slot, 5);
    check('decode group exact namekey', msg?.namekey, 'TacNet AQ==');
    check('group send exact channel allowed', channelSendAllowed(5, 'TacNet AQ=='), true);
}
{
    clearGroupChannels();
    localGroupChannels.add('TacNet AQ==');
    check('group mismatch wrong radio key not mapped', configureGroupChannel(5, 'TacNet Ag=='), false);
    check('group mismatch receive dropped', decodeTextFrame(RESP_CHANNEL_MSG_RECV, groupPayload(1, 5, 'wrong key')), null);
    check('group mismatch send blocked', channelSendAllowed(5, 'TacNet AQ=='), false);
    check('group mismatch wrong radio slot not mapped', configureGroupChannel(4, 'TacNet AQ=='), true);
    check('group mismatch receive wrong slot dropped', decodeTextFrame(RESP_CHANNEL_MSG_RECV, groupPayload(1, 5, 'wrong slot')), null);
    check('group mismatch send wrong slot blocked', channelSendAllowed(5, 'TacNet AQ=='), false);
}
{
    clearGroupChannels();
    localGroupChannels.add('V3 AQ==');
    configureGroupChannel(2, 'V3 AQ==');
    const d = decodeTextFrame(RESP_DIRECT_MSG_RECV_V3, directPayload(1, 2, 'v3d'));
    const g = decodeTextFrame(RESP_CHANNEL_MSG_RECV_V3, groupPayload(3, 2, 'v3g'));
    check('decode v3 direct', d?.data?.text_message, 'v3d');
    check('decode v3 group', g?.data?.text_message, 'v3g');
}
{
    clearGroupChannels();
    channelDataTextTypes.clear();
    channelDataStats.received = 0;
    channelDataStats.routed = 0;
    channelDataStats.unrouted = 0;
    localGroupChannels.add('Data AQ==');
    configureGroupChannel(3, 'Data AQ==');
    check('channel data malformed rejected', decodeTextFrame(RESP_CHANNEL_DATA_RECV, Buffer.alloc(8)), null);
    const datagram = channelDataPayload(3, 0xFFFF, 'payload');
    check('channel data disabled is unrouted', decodeTextFrame(RESP_CHANNEL_DATA_RECV, datagram), null);
    check('channel data disabled counted', channelDataStats.received, 1);
    channelDataTextTypes.add(0xFFFF);
    const msg = decodeTextFrame(RESP_CHANNEL_DATA_RECV, datagram);
    check('channel data enabled routes', msg?.data?.text_message, 'payload');
    check('channel data enabled slot', msg?.channel_index, 3);
    check('channel data enabled key', msg?.namekey, 'Data AQ==');
    check('channel data metadata type', msg?.metadata?.channel_data_type, 0xFFFF);
    check('channel data routed counted', channelDataStats.routed, 1);
    const tooLong = channelDataPayload(3, 0xFFFF, 'x'.repeat(MAX_CHANNEL_DATA_LENGTH + 1));
    check('channel data oversized rejected', decodeTextFrame(RESP_CHANNEL_DATA_RECV, tooLong), null);
}
{
    clearGroupChannels();
    check('startup ordering: discovery before local channel is not mapped', configureGroupChannel(6, 'Late AQ=='), false);
    localGroupChannels.add('Late AQ==');
    remapDiscoveredGroupChannels();
    check('startup ordering: exact tuple maps after local setup', channelSendAllowed(6, 'Late AQ=='), true);
    const g = decodeTextFrame(RESP_CHANNEL_MSG_RECV, groupPayload(1, 6, 'after setup'));
    check('startup ordering: receive allowed after remap', g?.namekey, 'Late AQ==');
}
{
    const a = new SmartAccumulator(STRICT_ON);
    const response = Buffer.concat([Buffer.from([RESP_CHANNEL_INFO, 0]), Buffer.from('TacNet'), Buffer.alloc(26), Buffer.alloc(16, 1)]);
    check('channel info no message', a.inject(Buffer.concat([Buffer.from([FRAME_FROM_RADIO, response.length & 0xFF, response.length >> 8]), response])).length, 0);
    check('channel info cached', a.stats.responses_cached, 1);
    check('channel info cached cmd', a.takeResponse(RESP_CHANNEL_INFO)?.cmd, RESP_CHANNEL_INFO);
}
{
    const cmd = buildCommand(CMD_SYNC_NEXT_MESSAGE);
    check('command marker', cmd[0], FRAME_TO_RADIO);
    check('command length LSB', cmd[1], 1);
    check('command payload code', cmd[3], CMD_SYNC_NEXT_MESSAGE);
}
{
    const direct = buildDirectSend('ABCDEF', 'hello', 2);
    check('direct tx command', direct[3], 0x02);
    check('direct tx retry', direct[5], 2);
    check('direct tx prefix', direct.subarray(10, 16).toString(), 'ABCDEF');
    const channel = buildChannelSend(4, 'hello');
    check('channel tx command', channel[3], 0x03);
    check('channel tx slot', channel[5], 4);
    check('channel tx text', channel.subarray(10).toString(), 'hello');
    check('USB crow profile', appStartPayload('crow_zeros').toString('hex'), '0000000000000043726f77');
    check('USB CLI profile', appStartPayload('meshcore_cli').toString('hex'), '0320202020202043726f77');
}
{
    const secret = Buffer.alloc(16, 0xA5);
    const set = setChannelCommand(1, 'CrowPriv', secret);
    check('private channel command', set[3], CMD_SET_CHANNEL);
    check('private channel slot', set[4], 1);
    check('private channel payload length', set.readUInt16LE(1), 50);
    check('private channel secret', set[37], 0xA5);

    const key = Buffer.alloc(32, 0x5A);
    const login = roomLoginCommand(key, 0, 'hello');
    check('room login command', login[3], CMD_SEND_ANON_REQ);
    check('room login full public key', login.subarray(4, 36).equals(key), true);
    check('room login password', login.subarray(44).toString(), 'hello');
    const contact = roomContactCommand(key, 'N9DK Room Server');
    check('room contact command', contact[3], CMD_ADD_UPDATE_CONTACT);
    check('room contact flood path', contact[38], 0xFF);
    check('room contact frame length', contact.readUInt16LE(1), 136);
}

console.log(`\n${count - failures} passed, ${failures} failed`);

const ucodePath = spawnSync('which', ['ucode'], { encoding: 'utf8' });
if (ucodePath.status === 0) {
    const uc = spawnSync('ucode', [path.join(__dirname, 'test_meshcore_tcp_api.uc')], { stdio: 'inherit' });
    if (uc.status !== 0) failures++;
}
else {
    console.log('ucode not found; skipped canonical .uc test');
}

process.exit(failures ? 1 : 0);
