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
const CMD_SEND_CHANNEL_TXT_MSG = 0x03;
const CMD_SYNC_NEXT_MESSAGE = 0x0A;
const RESP_DIRECT_MSG_RECV = 0x07;
const RESP_CHANNEL_MSG_RECV = 0x08;
const RESP_DIRECT_MSG_RECV_V3 = 0x10;
const RESP_CHANNEL_MSG_RECV_V3 = 0x11;
const RESP_CHANNEL_INFO = 0x12;
const CMD_ENCRYPTED_DM = 0x90;
const CMD_ENCRYPTED_BIN = 0x91;
const CMD_UNKNOWN = 0x77;

const PART97_BLOCKED_COMMANDS = new Set([CMD_ENCRYPTED_DM, CMD_ENCRYPTED_BIN]);

function isDirect(code) { return code === RESP_DIRECT_MSG_RECV || code === RESP_DIRECT_MSG_RECV_V3; }
function isGroup(code) { return code === RESP_CHANNEL_MSG_RECV || code === RESP_CHANNEL_MSG_RECV_V3; }
function isMessage(code) { return isDirect(code) || isGroup(code); }

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
            if (code === RESP_CHANNEL_INFO) {
                this.stats.responses_cached++;
                this.responses.push({ cmd: code, payload: framePayload });
                continue;
            }
            this.stats.early_drop_unknown_cmd++;
        }
    }
}

function receiveLayout(code, payload) {
    const off = code === RESP_DIRECT_MSG_RECV_V3 || code === RESP_CHANNEL_MSG_RECV_V3 ? 3 : 0;
    if (isDirect(code)) {
        if (payload.length < off + 12) return null;
        if (payload[off + 7] !== 0 && payload[off + 7] !== 2) return null;
        const textStart = off + 12 + (payload[off + 7] === 2 ? 4 : 0);
        return textStart <= payload.length ? { direct: true, off, textStart } : null;
    }
    if (isGroup(code)) {
        if (payload.length < off + 7 || payload[off] > 7 || payload[off + 2] !== 0) return null;
        return { direct: false, off, textStart: off + 7 };
    }
    return null;
}

function validTextPayload(code, payload) {
    return receiveLayout(code, payload) !== null;
}

function decodeTextFrame(cmd, payload) {
    const layout = receiveLayout(cmd, payload);
    if (!layout) return null;
    if (layout.direct) {
        const text = payload.subarray(layout.textStart).toString('utf8').replace(/\0+$/, '');
        if (!text.length) return null;
        return {
            from: payload.subarray(layout.off, layout.off + 6).toString('hex'),
            sender_timestamp: payload.readUInt32LE(layout.off + 8),
            transport: 'meshcore',
            backend: 'tcp_api',
            data: { text_message: text },
            metadata: { is_group_message: false, meshcore_response_code: cmd }
        };
    }
    if (!layout.direct) {
        const slot = payload[layout.off];
        const text = payload.subarray(layout.textStart).toString('utf8').replace(/\0+$/, '');
        if (!text.length) return null;
        return {
            group_slot: slot,
            sender_timestamp: payload.readUInt32LE(layout.off + 3),
            transport: 'meshcore',
            backend: 'tcp_api',
            data: { text_message: text },
            metadata: { is_group_message: true, group_slot: slot, meshcore_response_code: cmd }
        };
    }
    return null;
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

function buildGroupTextCommand(msg, slot) {
    const text = msg?.data?.text_message;
    if (typeof text !== 'string' || !text.length || slot < 0 || slot > 7) return null;
    const safe = Buffer.from(text.slice(0, 160), 'utf8');
    const timestamp = msg?.rx_time ?? Math.floor(Date.now() / 1000);
    return buildCommand(CMD_SEND_CHANNEL_TXT_MSG,
        Buffer.concat([Buffer.from([0, slot]), u32le(timestamp), safe]));
}

function u32le(n) { return Buffer.from([n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF]); }
function directPayload(from, _to, text) {
    return Buffer.concat([
        u32le(from), Buffer.from([0xaa, 0xbb, 0xff, 0x00]),
        u32le(0x55667788), Buffer.from(text)
    ]);
}
function groupPayload(_from, slot, text) {
    return Buffer.concat([Buffer.from([slot, 0xff, 0x00]), u32le(0x11223344), Buffer.from(text)]);
}

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
    a.inject(buildRadioFrame(CMD_ENCRYPTED_DM, Buffer.alloc(16)));
    check('encrypted strict drop', a.stats.early_drop_encrypted, 1);
}
{
    const a = new SmartAccumulator(STRICT_OFF);
    a.inject(buildRadioFrame(CMD_ENCRYPTED_DM, Buffer.alloc(16)));
    check('encrypted strict-off unknown', a.stats.early_drop_unknown_cmd, 1);
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
    const evil = Buffer.concat([Buffer.alloc(6), Buffer.from([0xff, 0x09]), u32le(0), Buffer.from('abc')]);
    check('malformed direct dropped', a.inject(buildRadioFrame(RESP_DIRECT_MSG_RECV, evil)).length, 0);
    check('malformed stat', a.stats.early_drop_malformed_text, 1);
}
{
    const msg = decodeTextFrame(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0, 'hi'));
    check('decode direct text', msg?.data?.text_message, 'hi');
    check('decode direct group flag', msg?.metadata?.is_group_message, false);
}
{
    const msg = decodeTextFrame(RESP_CHANNEL_MSG_RECV, groupPayload(0xDEADBEEF, 5, 'yo'));
    check('decode group text', msg?.data?.text_message, 'yo');
    check('decode group slot', msg?.group_slot, 5);
}
{
    const g = decodeTextFrame(RESP_CHANNEL_MSG_RECV_V3,
        Buffer.concat([Buffer.from([0xf8, 0, 0]), groupPayload(3, 2, 'v3g')]));
    const v3d = decodeTextFrame(RESP_DIRECT_MSG_RECV_V3,
        Buffer.concat([Buffer.from([0xf8, 0, 0]), directPayload(1, 2, 'v3d')]));
    check('decode v3 direct', v3d?.data?.text_message, 'v3d');
    check('decode v3 group', g?.data?.text_message, 'v3g');
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
    const cmd = buildGroupTextCommand({
        rx_time: 0x11223344,
        data: { text_message: 'Crow transmit' }
    }, 3);
    check('group send marker', cmd[0], FRAME_TO_RADIO);
    check('group send payload length', cmd.readUInt16LE(1), 1 + 1 + 1 + 4 + Buffer.byteLength('Crow transmit'));
    check('group send code', cmd[3], CMD_SEND_CHANNEL_TXT_MSG);
    check('group send text type', cmd[4], 0);
    check('group send slot', cmd[5], 3);
    check('group send timestamp', cmd.readUInt32LE(6), 0x11223344);
    check('group send text', cmd.subarray(10).toString(), 'Crow transmit');
    check('group send invalid slot', buildGroupTextCommand({ data: { text_message: 'no' } }, 8), null);
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
