// Tests for meshcore_tcp_api.uc Smart Accumulator and decoder.
//
// Runs under ucode against the real module. The module exports
// _test_inject / _test_reset / _test_stats / _test_build_frame for
// hermetic state-machine testing without a live socket.

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
const CMD_ENCRYPTED_DM  = 0x90;
const CMD_ADVERT        = 0x83;
const CMD_UNKNOWN       = 0x77;

function u32le(n)
{
    return chr(n & 0xFF) + chr((n >> 8) & 0xFF) + chr((n >> 16) & 0xFF) + chr((n >> 24) & 0xFF);
}

function textPayload(from, to, text)
{
    return u32le(from) + u32le(to) + chr(length(text)) + text;
}

// ---- Test 1: Single complete TXT_MSG frame decodes ----
api._test_reset();
{
    const payload = textPayload(0x11223344, 0x55667788, "hello mesh");
    const frame = api._test_build_frame(CMD_TXT_MSG, payload);
    const frames = api._test_inject(frame, STRICT_ON);
    check("single frame: count", length(frames), 1);
    check("single frame: cmd",   frames[0]?.cmd, CMD_TXT_MSG);
    check("single frame: payload length", length(frames[0]?.payload), length(payload));
}

// ---- Test 2: Fragmented frame across 3 reads ----
api._test_reset();
{
    const payload = textPayload(0xDEADBEEF, 0, "fragment me");
    const frame   = api._test_build_frame(CMD_GRP_TXT, payload);
    const a = substr(frame, 0, 2);
    const b = substr(frame, 2, 5);
    const c = substr(frame, 7);

    let frames = api._test_inject(a, STRICT_ON);
    check("fragmented: read 1 yields nothing", length(frames), 0);
    frames = api._test_inject(b, STRICT_ON);
    check("fragmented: read 2 yields nothing", length(frames), 0);
    frames = api._test_inject(c, STRICT_ON);
    check("fragmented: read 3 completes",      length(frames), 1);
    check("fragmented: cmd correct",           frames[0]?.cmd, CMD_GRP_TXT);
}

// ---- Test 3: Oversize kill switch ----
api._test_reset();
{
    // Hand-build a frame claiming a 60000-byte payload.
    const hdr = chr(0x3E) + chr(CMD_TXT_MSG) + chr(0xEA) + chr(0x60);  // 0xEA60 = 60000
    const frames = api._test_inject(hdr, STRICT_ON);
    check("oversize: zero frames emitted", length(frames), 0);
    check("oversize: stat incremented",
        api._test_stats().early_drop_oversize, 1);
}

// ---- Test 4: Encrypted early-drop under strict mode ----
api._test_reset();
{
    const enc = api._test_build_frame(CMD_ENCRYPTED_DM, "X" * 32);
    const frames = api._test_inject(enc, STRICT_ON);
    check("encrypted: dropped",              length(frames), 0);
    check("encrypted: stat incremented",
        api._test_stats().early_drop_encrypted, 1);
}

// ---- Test 5: Encrypted frames pass through when strict mode OFF ----
// (They're still rejected as unknown-cleartext at the unknown-cmd gate,
//  but NOT counted under early_drop_encrypted.)
api._test_reset();
{
    const enc = api._test_build_frame(CMD_ENCRYPTED_DM, "X" * 16);
    api._test_inject(enc, STRICT_OFF);
    check("encrypted strict-off: not counted as encrypted drop",
        api._test_stats().early_drop_encrypted, 0);
    check("encrypted strict-off: counted as unknown-cmd drop",
        api._test_stats().early_drop_unknown_cmd, 1);
}

// ---- Test 6: Unknown command early-drop ----
api._test_reset();
{
    const f = api._test_build_frame(CMD_UNKNOWN, "junk-payload");
    const frames = api._test_inject(f, STRICT_ON);
    check("unknown cmd: dropped",            length(frames), 0);
    check("unknown cmd: stat incremented",
        api._test_stats().early_drop_unknown_cmd, 1);
}

// ---- Test 7: Pre-magic garbage triggers resync ----
api._test_reset();
{
    const garbage = "\x00\x01\x02\x99\xAA\xBB";
    const payload = textPayload(0xABCDEF01, 0, "after garbage");
    const frame   = api._test_build_frame(CMD_TXT_MSG, payload);
    const frames  = api._test_inject(garbage + frame, STRICT_ON);
    check("resync: one frame after garbage", length(frames), 1);
    checkTrue("resync: stat incremented",     api._test_stats().resync_skips >= 1);
}

// ---- Test 8: Back-to-back frames in one read ----
api._test_reset();
{
    const p1 = textPayload(1, 2, "one");
    const p2 = textPayload(3, 4, "two");
    const buf = api._test_build_frame(CMD_TXT_MSG, p1)
              + api._test_build_frame(CMD_TXT_MSG, p2);
    const frames = api._test_inject(buf, STRICT_ON);
    check("back-to-back: 2 frames", length(frames), 2);
}

// ---- Test 9: ADVERT decodes to no message but is not an error ----
api._test_reset();
{
    const adv = api._test_build_frame(CMD_ADVERT, "advert-body");
    const frames = api._test_inject(adv, STRICT_ON);
    check("advert: 1 raw frame",     length(frames), 1);
    check("advert: cmd correct",     frames[0]?.cmd, CMD_ADVERT);
    check("advert: NOT in early-drop encrypted",
        api._test_stats().early_drop_encrypted, 0);
}

printf("\n%d passed, %d failed\n", count - failures, failures);
exit(failures > 0 ? 1 : 0);
