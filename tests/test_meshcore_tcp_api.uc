// Tests for meshcore_tcp_api.uc Smart Accumulator and decoder.
//
// Scope: this backend ONLY emits TXT_MSG / GRP_TXT. Every other frame
// type — handshake responses, adverts, encrypted blobs, unknown commands
// — must be dropped at the accumulator without allocating a payload.

import * as api from "../meshcore_tcp_api.uc";

let failures = 0;
let count = 0;

function check(name, got, want)
{
    count++;
    if (got === want) {
        printf("ok   - %s\n", name);
        return;
    }
    failures++;
    printf("FAIL - %s\n   got:  %s\n   want: %s\n", name, got, want);
}

function checkTrue(name, got)
{
    check(name, !!got, true);
}

// Stub DEBUG sinks so the module is silent.
global.DEBUG0 = function (...args) {};
global.DEBUG1 = function (...args) {};

const STRICT_ON  = { isEnabled: () => true };
const STRICT_OFF = { isEnabled: () => false };

const CMD_TXT_MSG       = 0x81;
const CMD_GRP_TXT       = 0x82;
const CMD_ADVERT        = 0x83;
const CMD_HELLO_RESP    = 0x80;
const CMD_ENCRYPTED_DM  = 0x90;
const CMD_UNKNOWN       = 0x77;

function u32le(n)
{
    return chr(n & 0xFF) + chr((n >> 8) & 0xFF) + chr((n >> 16) & 0xFF) + chr((n >> 24) & 0xFF);
}

function textPayload(from, to, text)
{
    return u32le(from) + u32le(to) + chr(length(text)) + text;
}

// ---- 1. Single complete TXT_MSG frame decodes through the accumulator
api._test_reset();
{
    const payload = textPayload(0x11223344, 0x55667788, "hello mesh");
    const frame = api._test_build_frame(CMD_TXT_MSG, payload);
    const frames = api._test_inject(frame, STRICT_ON);
    check("single frame: count", length(frames), 1);
    check("single frame: cmd",   frames[0]?.cmd, CMD_TXT_MSG);
    check("single frame: payload length", length(frames[0]?.payload), length(payload));
}

// ---- 2. Fragmented frame across 3 reads
api._test_reset();
{
    const payload = textPayload(0xDEADBEEF, 0, "fragment me");
    const frame   = api._test_build_frame(CMD_GRP_TXT, payload);
    const a = substr(frame, 0, 2);
    const b = substr(frame, 2, 5);
    const c = substr(frame, 7);

    check("fragmented: read 1 yields nothing", length(api._test_inject(a, STRICT_ON)), 0);
    check("fragmented: read 2 yields nothing", length(api._test_inject(b, STRICT_ON)), 0);
    const f = api._test_inject(c, STRICT_ON);
    check("fragmented: read 3 completes", length(f), 1);
    check("fragmented: cmd correct",      f[0]?.cmd, CMD_GRP_TXT);
}

// ---- 3. Oversize kill switch (claim > SMART_MAX_PAYLOAD)
api._test_reset();
{
    const hdr = chr(0x3E) + chr(CMD_TXT_MSG) + chr(0xEA) + chr(0x60);  // claim 60000
    const frames = api._test_inject(hdr, STRICT_ON);
    check("oversize: zero frames emitted", length(frames), 0);
    check("oversize: stat incremented",
        api._test_stats().early_drop_oversize, 1);
}

// ---- 4. Boundary: SMART_MAX_PAYLOAD = 256, so 257 is rejected
api._test_reset();
{
    const hdr = chr(0x3E) + chr(CMD_TXT_MSG) + chr(0x01) + chr(0x01);  // 257
    api._test_inject(hdr, STRICT_ON);
    check("boundary 257: rejected", api._test_stats().early_drop_oversize, 1);
}

// ---- 5. Encrypted early-drop under strict mode
api._test_reset();
{
    const enc = api._test_build_frame(CMD_ENCRYPTED_DM, "X" * 32);
    check("encrypted: dropped",
        length(api._test_inject(enc, STRICT_ON)), 0);
    check("encrypted: stat incremented",
        api._test_stats().early_drop_encrypted, 1);
}

// ---- 6. Encrypted frames with strict OFF → unknown-cmd gate
api._test_reset();
{
    const enc = api._test_build_frame(CMD_ENCRYPTED_DM, "X" * 16);
    api._test_inject(enc, STRICT_OFF);
    check("encrypted strict-off: not counted as encrypted drop",
        api._test_stats().early_drop_encrypted, 0);
    check("encrypted strict-off: counted as unknown-cmd drop",
        api._test_stats().early_drop_unknown_cmd, 1);
}

// ---- 7. Unknown command early-drop
api._test_reset();
{
    const f = api._test_build_frame(CMD_UNKNOWN, "junk-payload");
    check("unknown cmd: dropped",
        length(api._test_inject(f, STRICT_ON)), 0);
    check("unknown cmd: stat incremented",
        api._test_stats().early_drop_unknown_cmd, 1);
}

// ---- 8. ADVERT is NOT emitted (text-only contract)
api._test_reset();
{
    const adv = api._test_build_frame(CMD_ADVERT, "advert-body");
    check("advert: dropped at unknown-cmd gate",
        length(api._test_inject(adv, STRICT_ON)), 0);
    check("advert: stat incremented",
        api._test_stats().early_drop_unknown_cmd, 1);
}

// ---- 9. HELLO_RESP is NOT emitted (text-only contract)
api._test_reset();
{
    const hr = api._test_build_frame(CMD_HELLO_RESP, "ok");
    check("hello_resp: dropped at unknown-cmd gate",
        length(api._test_inject(hr, STRICT_ON)), 0);
    check("hello_resp: stat incremented",
        api._test_stats().early_drop_unknown_cmd, 1);
}

// ---- 10. Pre-magic garbage triggers resync
api._test_reset();
{
    const garbage = "\x00\x01\x02\x99\xAA\xBB";
    const payload = textPayload(0xABCDEF01, 0, "after garbage");
    const frame   = api._test_build_frame(CMD_TXT_MSG, payload);
    const frames  = api._test_inject(garbage + frame, STRICT_ON);
    check("resync: one frame after garbage", length(frames), 1);
    checkTrue("resync: stat incremented",     api._test_stats().resync_skips >= 1);
}

// ---- 11. Back-to-back frames
api._test_reset();
{
    const p1 = textPayload(1, 2, "one");
    const p2 = textPayload(3, 4, "two");
    const buf = api._test_build_frame(CMD_TXT_MSG, p1)
              + api._test_build_frame(CMD_TXT_MSG, p2);
    check("back-to-back: 2 frames",
        length(api._test_inject(buf, STRICT_ON)), 2);
}

// ---- 12. Multi-read oversize drain — buffer recovers to next valid frame
api._test_reset();
{
    // Claim 1024 bytes (well over 256 cap)
    api._test_inject(chr(0x3E) + chr(CMD_TXT_MSG) + chr(0x04) + chr(0x00), STRICT_ON);
    api._test_inject("\xAA" * 600, STRICT_ON);
    api._test_inject("\xAA" * 424, STRICT_ON);
    const good = api._test_build_frame(CMD_TXT_MSG, textPayload(7, 8, "ok"));
    const f = api._test_inject(good, STRICT_ON);
    check("oversize drain: next valid frame parses", length(f), 1);
    check("oversize drain: cmd correct", f[0]?.cmd, CMD_TXT_MSG);
}

// ---- 13. Malformed text — length byte exceeds plen
api._test_reset();
{
    // text envelope: from(4)+to(4)+tlen(1)+text(n). Claim plen=12 but
    // text-length byte says 99 bytes follow (impossible).
    const evil = u32le(1) + u32le(2) + chr(99) + "abc";  // plen will be 12
    const frame = api._test_build_frame(CMD_TXT_MSG, evil);
    check("malformed: dropped",
        length(api._test_inject(frame, STRICT_ON)), 0);
    check("malformed: stat incremented",
        api._test_stats().early_drop_malformed_text, 1);
}

// ---- 14. Decoder: TXT_MSG produces correct Crow msg shape
api._test_reset();
{
    const payload = textPayload(0xCAFEBABE, 0x00000000, "hi");
    const msg = api._test_decode(CMD_TXT_MSG, payload);
    check("decode TXT: transport", msg?.transport, "meshcore");
    check("decode TXT: backend",   msg?.backend,   "tcp_api");
    check("decode TXT: from",      msg?.from,      0xCAFEBABE);
    check("decode TXT: to",        msg?.to,        0);
    check("decode TXT: text",      msg?.data?.text_message, "hi");
    check("decode TXT: not group", msg?.is_group, null);
}

// ---- 15. Decoder: GRP_TXT marks is_group
api._test_reset();
{
    const payload = textPayload(0xDEADBEEF, 0, "yo");
    const msg = api._test_decode(CMD_GRP_TXT, payload);
    check("decode GRP: is_group", msg?.is_group, true);
}

printf("\n%d passed, %d failed\n", count - failures, failures);
exit(failures > 0 ? 1 : 0);
