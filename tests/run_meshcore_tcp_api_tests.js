// Node-runnable mirror of test_meshcore_tcp_api.uc.
//
// Re-implements the Smart Accumulator logic from meshcore_tcp_api.uc in
// JavaScript so we can exercise the state machine on a dev laptop that
// doesn't have the ucode interpreter. If `ucode` is on PATH, the canonical
// .uc tests are invoked at the end.

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

// ---------- Smart Accumulator (mirror of meshcore_tcp_api.uc) ----------

const COMPANION_MAGIC      = 0x3E;
const HEADER_BYTES         = 4;
const SMART_MAX_PAYLOAD    = 512;
const RESYNC_BUFFER_CAP    = 4096;

const CMD_HELLO_RESP       = 0x80;
const CMD_TXT_MSG          = 0x81;
const CMD_GRP_TXT          = 0x82;
const CMD_ADVERT           = 0x83;
const CMD_ENCRYPTED_DM     = 0x90;
const CMD_ENCRYPTED_BIN    = 0x91;

const CLEARTEXT_COMMANDS = new Set([
    CMD_HELLO_RESP, CMD_TXT_MSG, CMD_GRP_TXT, CMD_ADVERT
]);
const PART97_BLOCKED_COMMANDS = new Set([
    CMD_ENCRYPTED_DM, CMD_ENCRYPTED_BIN
]);

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
            resync_skips: 0
        };
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

        this.buf = Buffer.concat([this.buf, chunk]);
        const strictOn = this.gatekeeper && this.gatekeeper.isEnabled();

        for (;;) {
            let start = -1;
            for (let i = 0; i < this.buf.length; i++) {
                if (this.buf[i] === COMPANION_MAGIC) { start = i; break; }
            }
            if (start < 0) {
                if (this.buf.length > RESYNC_BUFFER_CAP) {
                    this.stats.resync_skips++;
                    this.buf = Buffer.alloc(0);
                }
                return frames;
            }
            if (start > 0) {
                this.stats.resync_skips++;
                this.buf = this.buf.subarray(start);
            }
            if (this.buf.length < HEADER_BYTES) return frames;

            const cmd  = this.buf[1];
            const plen = (this.buf[2] << 8) | this.buf[3];

            if (plen > SMART_MAX_PAYLOAD) {
                this.stats.early_drop_oversize++;
                this.buf = this.buf.subarray(HEADER_BYTES);
                this.pendingSkip = plen;
                if (this.pendingSkip > 0 && this.buf.length > 0) {
                    const drop = Math.min(this.pendingSkip, this.buf.length);
                    this.buf = this.buf.subarray(drop);
                    this.pendingSkip -= drop;
                }
                continue;
            }

            if (strictOn && PART97_BLOCKED_COMMANDS.has(cmd)) {
                this.stats.early_drop_encrypted++;
                if (this.buf.length >= HEADER_BYTES + plen) {
                    this.buf = this.buf.subarray(HEADER_BYTES + plen);
                } else {
                    this.pendingSkip = HEADER_BYTES + plen - this.buf.length;
                    this.buf = Buffer.alloc(0);
                }
                continue;
            }

            if (!CLEARTEXT_COMMANDS.has(cmd)) {
                this.stats.early_drop_unknown_cmd++;
                if (this.buf.length >= HEADER_BYTES + plen) {
                    this.buf = this.buf.subarray(HEADER_BYTES + plen);
                } else {
                    this.pendingSkip = HEADER_BYTES + plen - this.buf.length;
                    this.buf = Buffer.alloc(0);
                }
                continue;
            }

            if (this.buf.length < HEADER_BYTES + plen) return frames;

            const payload = this.buf.subarray(HEADER_BYTES, HEADER_BYTES + plen);
            this.buf = this.buf.subarray(HEADER_BYTES + plen);
            this.stats.frames_in++;
            frames.push({ cmd, payload });
        }
    }
}

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
    if (got === want || (Buffer.isBuffer(got) && Buffer.isBuffer(want) && got.equals(want))) {
        console.log(`ok   - ${name}`);
    } else {
        failures++;
        console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`);
    }
}
function checkTrue(name, got) { check(name, !!got, true); }

const STRICT_ON  = { isEnabled: () => true };
const STRICT_OFF = { isEnabled: () => false };

// 1. single frame
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
    const f = a.inject(hdr);
    check('oversize: zero frames emitted', f.length, 0);
    check('oversize: stat incremented', a.stats.early_drop_oversize, 1);
}

// 4. encrypted early-drop under strict
{
    const a = new SmartAccumulator(STRICT_ON);
    const enc = buildFrame(CMD_ENCRYPTED_DM, Buffer.alloc(32, 0x58));
    const f = a.inject(enc);
    check('encrypted: dropped', f.length, 0);
    check('encrypted: stat incremented', a.stats.early_drop_encrypted, 1);
}

// 5. encrypted with strict OFF -> falls to unknown-cmd gate
{
    const a = new SmartAccumulator(STRICT_OFF);
    a.inject(buildFrame(CMD_ENCRYPTED_DM, Buffer.alloc(16, 0x58)));
    check('encrypted strict-off: not counted as encrypted drop',
        a.stats.early_drop_encrypted, 0);
    check('encrypted strict-off: counted as unknown-cmd drop',
        a.stats.early_drop_unknown_cmd, 1);
}

// 6. unknown cmd
{
    const a = new SmartAccumulator(STRICT_ON);
    const f = a.inject(buildFrame(0x77, Buffer.from('junk-payload')));
    check('unknown cmd: dropped', f.length, 0);
    check('unknown cmd: stat incremented', a.stats.early_drop_unknown_cmd, 1);
}

// 7. pre-magic garbage
{
    const a = new SmartAccumulator(STRICT_ON);
    const garbage = Buffer.from([0x00, 0x01, 0x02, 0x99, 0xAA, 0xBB]);
    const frame = buildFrame(CMD_TXT_MSG, textPayload(0xABCDEF01, 0, 'after garbage'));
    const f = a.inject(Buffer.concat([garbage, frame]));
    check('resync: one frame after garbage', f.length, 1);
    checkTrue('resync: stat incremented', a.stats.resync_skips >= 1);
}

// 8. back-to-back
{
    const a = new SmartAccumulator(STRICT_ON);
    const buf = Buffer.concat([
        buildFrame(CMD_TXT_MSG, textPayload(1, 2, 'one')),
        buildFrame(CMD_TXT_MSG, textPayload(3, 4, 'two'))
    ]);
    check('back-to-back: 2 frames', a.inject(buf).length, 2);
}

// 9. advert passes the smart accumulator
{
    const a = new SmartAccumulator(STRICT_ON);
    const f = a.inject(buildFrame(CMD_ADVERT, Buffer.from('advert-body')));
    check('advert: 1 raw frame',  f.length, 1);
    check('advert: cmd correct',  f[0]?.cmd, CMD_ADVERT);
    check('advert: NOT in early-drop encrypted', a.stats.early_drop_encrypted, 0);
}

// 10. oversize payload across multiple reads is fully drained
{
    const a = new SmartAccumulator(STRICT_ON);
    a.inject(Buffer.from([COMPANION_MAGIC, CMD_TXT_MSG, 0x04, 0x00])); // claim 1024
    a.inject(Buffer.alloc(600, 0xAA));   // half of the bogus payload
    a.inject(Buffer.alloc(424, 0xAA));   // the rest
    const goodFrame = buildFrame(CMD_TXT_MSG, textPayload(7, 8, 'ok'));
    const f = a.inject(goodFrame);
    check('oversize drain: next valid frame still parses', f.length, 1);
    check('oversize drain: cmd correct', f[0]?.cmd, CMD_TXT_MSG);
}

console.log(`\nJS:    ${count - failures} passed, ${failures} failed`);

// Try ucode tests too, if available.
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
