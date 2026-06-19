// Node-runnable mirror of test_meshcore_tcp_api.uc.
//
// Re-implements the Smart Accumulator + text decoder from
// meshcore_tcp_api.uc so the state machine can be exercised on a dev
// laptop that doesn't have the ucode interpreter. If `ucode` is on PATH,
// the canonical .uc tests are invoked at the end.
//
// Contract under test (text-only):
//   - Accumulator only EMITS frames for cmd ∈ { TXT_MSG, GRP_TXT }.
//   - HELLO_RESP, ADVERT, encrypted, unknown — all dropped at buffer
//     level without payload allocation.
//   - SMART_MAX_PAYLOAD = 256.
//   - Malformed text frames (tlen byte > plen) are dropped early.

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

// ---------- Constants (mirror of meshcore_tcp_api.uc) ----------

const COMPANION_MAGIC      = 0x3E;
const HEADER_BYTES         = 4;
const SMART_MAX_PAYLOAD    = 256;
const RESYNC_BUFFER_CAP    = 4096;
const TEXT_ENVELOPE_BYTES  = 9;

const CMD_TXT_MSG          = 0x81;
const CMD_GRP_TXT          = 0x82;
const CMD_ADVERT           = 0x83;
const CMD_HELLO_RESP       = 0x80;
const CMD_ENCRYPTED_DM     = 0x90;
const CMD_ENCRYPTED_BIN    = 0x91;

const PART97_BLOCKED_COMMANDS = new Set([CMD_ENCRYPTED_DM, CMD_ENCRYPTED_BIN]);

// ---------- Smart Accumulator ----------

class SmartAccumulator
{
    constructor(gatekeeper)
    {
        this.gatekeeper = gatekeeper;
        this.buf = Buffer.alloc(0);
        this.pendingSkip = 0;
        this.stats = {
            frames_in: 0,
            early_drop_oversize: 0,
            early_drop_encrypted: 0,
            early_drop_unknown_cmd: 0,
            early_drop_malformed_text: 0,
            resync_skips: 0
        };
    }

    _advance(hdrBytes, payloadBytes)
    {
        const total = hdrBytes + payloadBytes;
        if (this.buf.length >= total) {
            this.buf = this.buf.subarray(total);
            return;
        }
        this.pendingSkip = total - this.buf.length;
        this.buf = Buffer.alloc(0);
    }

    inject(data)
    {
        const frames = [];
        let chunk = Buffer.isBuffer(data) ? data : Buffer.from(data, 'binary');

        if (this.pendingSkip > 0 && chunk.length > 0) {
            const drop = Math.min(this.pendingSkip, chunk.length);
            chunk = chunk.subarray(drop);
            this.pendingSkip -= drop;
            if (this.pendingSkip > 0) return frames;
        }

        if (chunk.length > 0) {
            this.buf = Buffer.concat([this.buf, chunk]);
        }
        const strictOn = this.gatekeeper && this.gatekeeper.isEnabled();

        for (;;) {
            const blen = this.buf.length;
            if (blen === 0) return frames;

            // Resync
            if (this.buf[0] !== COMPANION_MAGIC) {
                let start = -1;
                for (let i = 1; i < blen; i++) {
                    if (this.buf[i] === COMPANION_MAGIC) { start = i; break; }
                }
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

            const cmd  = this.buf[1];
            const plen = (this.buf[2] << 8) | this.buf[3];

            // Oversize
            if (plen > SMART_MAX_PAYLOAD) {
                this.stats.early_drop_oversize++;
                this._advance(HEADER_BYTES, plen);
                continue;
            }
            // Encrypted (strict)
            if (strictOn && PART97_BLOCKED_COMMANDS.has(cmd)) {
                this.stats.early_drop_encrypted++;
                this._advance(HEADER_BYTES, plen);
                continue;
            }
            // Unknown cmd (anything not TXT_MSG or GRP_TXT)
            if (cmd !== CMD_TXT_MSG && cmd !== CMD_GRP_TXT) {
                this.stats.early_drop_unknown_cmd++;
                this._advance(HEADER_BYTES, plen);
                continue;
            }
            // Wait for full payload
            if (blen < HEADER_BYTES + plen) return frames;

            // Inline text-envelope sanity
            if (plen < TEXT_ENVELOPE_BYTES) {
                this.stats.early_drop_malformed_text++;
                this.buf = this.buf.subarray(HEADER_BYTES + plen);
                continue;
            }
            const tlen = this.buf[HEADER_BYTES + 8];
            if (TEXT_ENVELOPE_BYTES + tlen > plen) {
                this.stats.early_drop_malformed_text++;
                this.buf = this.buf.subarray(HEADER_BYTES + plen);
                continue;
            }

            const payload = this.buf.subarray(HEADER_BYTES, HEADER_BYTES + plen);
            this.buf = this.buf.subarray(HEADER_BYTES + plen);
            this.stats.frames_in++;
            frames.push({ cmd, payload });
        }
    }
}

// ---------- Decoder ----------

function decodeTextFrame(cmd, payload)
{
    const fromId = payload.readUInt32LE(0);
    const toId   = payload.readUInt32LE(4);
    const tlen   = payload[8];
    let text     = payload.subarray(9, 9 + tlen).toString('utf8');
    // Strip trailing NULs
    text = text.replace(/\0+$/, '');
    if (!text.length) return null;
    const msg = {
        from: fromId, to: toId,
        transport: 'meshcore', backend: 'tcp_api',
        data: { text_message: text }
    };
    if (cmd === CMD_GRP_TXT) msg.is_group = true;
    return msg;
}

// ---------- Helpers ----------

function buildFrame(cmd, payload)
{
    const p = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || '', 'binary');
    return Buffer.concat([
        Buffer.from([COMPANION_MAGIC, cmd & 0xFF, (p.length >> 8) & 0xFF, p.length & 0xFF]),
        p
    ]);
}
function u32le(n)
{
    return Buffer.from([n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF]);
}
function textPayload(from, to, text)
{
    const t = Buffer.from(text, 'utf8');
    return Buffer.concat([u32le(from), u32le(to), Buffer.from([t.length]), t]);
}

// ---------- Tests ----------

let failures = 0, count = 0;

function check(name, got, want)
{
    count++;
    const same = got === want
        || (Buffer.isBuffer(got) && Buffer.isBuffer(want) && got.equals(want));
    if (same) console.log(`ok   - ${name}`);
    else { failures++; console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`); }
}
function checkTrue(name, got) { check(name, !!got, true); }

const STRICT_ON  = { isEnabled: () => true };
const STRICT_OFF = { isEnabled: () => false };

// 1. single TXT_MSG
{
    const a = new SmartAccumulator(STRICT_ON);
    const payload = textPayload(0x11223344, 0x55667788, 'hello mesh');
    const f = a.inject(buildFrame(CMD_TXT_MSG, payload));
    check('single frame: count', f.length, 1);
    check('single frame: cmd',   f[0]?.cmd, CMD_TXT_MSG);
    check('single frame: payload length', f[0]?.payload.length, payload.length);
}

// 2. fragmentation
{
    const a = new SmartAccumulator(STRICT_ON);
    const frame = buildFrame(CMD_GRP_TXT, textPayload(0xDEADBEEF, 0, 'fragment me'));
    check('fragmented: read 1 yields nothing', a.inject(frame.subarray(0, 2)).length, 0);
    check('fragmented: read 2 yields nothing', a.inject(frame.subarray(2, 7)).length, 0);
    const f = a.inject(frame.subarray(7));
    check('fragmented: read 3 completes', f.length, 1);
    check('fragmented: cmd correct',      f[0]?.cmd, CMD_GRP_TXT);
}

// 3. oversize kill switch
{
    const a = new SmartAccumulator(STRICT_ON);
    const hdr = Buffer.from([COMPANION_MAGIC, CMD_TXT_MSG, 0xEA, 0x60]); // 60000
    check('oversize: zero frames emitted', a.inject(hdr).length, 0);
    check('oversize: stat incremented',    a.stats.early_drop_oversize, 1);
}

// 4. boundary: 257 > 256 cap
{
    const a = new SmartAccumulator(STRICT_ON);
    const hdr = Buffer.from([COMPANION_MAGIC, CMD_TXT_MSG, 0x01, 0x01]);
    a.inject(hdr);
    check('boundary 257: rejected', a.stats.early_drop_oversize, 1);
}

// 5. encrypted early-drop under strict
{
    const a = new SmartAccumulator(STRICT_ON);
    const enc = buildFrame(CMD_ENCRYPTED_DM, Buffer.alloc(32, 0x58));
    check('encrypted: dropped', a.inject(enc).length, 0);
    check('encrypted: stat incremented', a.stats.early_drop_encrypted, 1);
}

// 6. encrypted with strict OFF -> falls to unknown-cmd gate
{
    const a = new SmartAccumulator(STRICT_OFF);
    a.inject(buildFrame(CMD_ENCRYPTED_DM, Buffer.alloc(16, 0x58)));
    check('encrypted strict-off: not counted as encrypted drop',
        a.stats.early_drop_encrypted, 0);
    check('encrypted strict-off: counted as unknown-cmd drop',
        a.stats.early_drop_unknown_cmd, 1);
}

// 7. unknown cmd
{
    const a = new SmartAccumulator(STRICT_ON);
    const f = a.inject(buildFrame(0x77, Buffer.from('junk-payload')));
    check('unknown cmd: dropped', f.length, 0);
    check('unknown cmd: stat incremented', a.stats.early_drop_unknown_cmd, 1);
}

// 8. ADVERT is NOT emitted (text-only contract)
{
    const a = new SmartAccumulator(STRICT_ON);
    const adv = buildFrame(CMD_ADVERT, Buffer.from('advert-body'));
    check('advert: dropped at unknown-cmd gate', a.inject(adv).length, 0);
    check('advert: stat incremented',            a.stats.early_drop_unknown_cmd, 1);
}

// 9. HELLO_RESP is NOT emitted
{
    const a = new SmartAccumulator(STRICT_ON);
    const hr = buildFrame(CMD_HELLO_RESP, Buffer.from('ok'));
    check('hello_resp: dropped at unknown-cmd gate', a.inject(hr).length, 0);
    check('hello_resp: stat incremented',            a.stats.early_drop_unknown_cmd, 1);
}

// 10. pre-magic garbage
{
    const a = new SmartAccumulator(STRICT_ON);
    const garbage = Buffer.from([0x00, 0x01, 0x02, 0x99, 0xAA, 0xBB]);
    const frame = buildFrame(CMD_TXT_MSG, textPayload(0xABCDEF01, 0, 'after garbage'));
    const f = a.inject(Buffer.concat([garbage, frame]));
    check('resync: one frame after garbage', f.length, 1);
    checkTrue('resync: stat incremented', a.stats.resync_skips >= 1);
}

// 11. back-to-back
{
    const a = new SmartAccumulator(STRICT_ON);
    const buf = Buffer.concat([
        buildFrame(CMD_TXT_MSG, textPayload(1, 2, 'one')),
        buildFrame(CMD_TXT_MSG, textPayload(3, 4, 'two'))
    ]);
    check('back-to-back: 2 frames', a.inject(buf).length, 2);
}

// 12. multi-read oversize drain
{
    const a = new SmartAccumulator(STRICT_ON);
    a.inject(Buffer.from([COMPANION_MAGIC, CMD_TXT_MSG, 0x04, 0x00])); // claim 1024
    a.inject(Buffer.alloc(600, 0xAA));
    a.inject(Buffer.alloc(424, 0xAA));
    const f = a.inject(buildFrame(CMD_TXT_MSG, textPayload(7, 8, 'ok')));
    check('oversize drain: next valid frame parses', f.length, 1);
    check('oversize drain: cmd correct',             f[0]?.cmd, CMD_TXT_MSG);
}

// 13. malformed text — tlen > plen
{
    const a = new SmartAccumulator(STRICT_ON);
    const evil = Buffer.concat([u32le(1), u32le(2), Buffer.from([99]), Buffer.from('abc')]);
    const frame = buildFrame(CMD_TXT_MSG, evil);
    check('malformed: dropped', a.inject(frame).length, 0);
    check('malformed: stat incremented', a.stats.early_drop_malformed_text, 1);
}

// 14. Decoder: TXT_MSG
{
    const payload = textPayload(0xCAFEBABE, 0x00000000, 'hi');
    const msg = decodeTextFrame(CMD_TXT_MSG, payload);
    check('decode TXT: transport', msg?.transport, 'meshcore');
    check('decode TXT: backend',   msg?.backend,   'tcp_api');
    check('decode TXT: from',      msg?.from,      0xCAFEBABE);
    check('decode TXT: to',        msg?.to,        0);
    check('decode TXT: text',      msg?.data?.text_message, 'hi');
    check('decode TXT: not group', msg?.is_group ?? false, false);
}

// 15. Decoder: GRP_TXT
{
    const payload = textPayload(0xDEADBEEF, 0, 'yo');
    const msg = decodeTextFrame(CMD_GRP_TXT, payload);
    check('decode GRP: is_group', msg?.is_group, true);
}

console.log(`\nJS:    ${count - failures} passed, ${failures} failed`);

// ucode invocation if available
let ucPath = '';
try {
    const r = spawnSync('which', ['ucode'], { encoding: 'utf8' });
    if (r.status === 0) ucPath = r.stdout.trim();
} catch (_) {}

if (ucPath) {
    const r = spawnSync(ucPath, ['-R', '-L', path.join(__dirname, 'test_meshcore_tcp_api.uc')], {
        cwd: path.dirname(__dirname),
        encoding: 'utf8'
    });
    process.stdout.write(r.stdout || '');
    process.stderr.write(r.stderr || '');
    if (r.status !== 0) failures++;
} else {
    console.log('ucode: skipped (ucode not on PATH)');
}

process.exit(failures > 0 ? 1 : 0);
