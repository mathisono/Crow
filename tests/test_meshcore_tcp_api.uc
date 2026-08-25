// Tests for meshcore_tcp_api.uc stock MeshCore TCP / Serial-WiFi framing.
//
// Radio -> client frames:
//   [ '>' ][ length LSB ][ length MSB ][ frame payload ]
//
// Client -> radio frames:
//   [ '<' ][ length LSB ][ length MSB ][ frame payload ]
//
// The frame payload begins with the MeshCore command/response code.

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

global.DEBUG0 = function (...args) {};
global.DEBUG1 = function (...args) {};

const STRICT_ON  = { isEnabled: () => true };
const STRICT_OFF = { isEnabled: () => false };

const PUSH_CODE_MSG_WAITING    = 0x83;
const CMD_SYNC_NEXT_MESSAGE    = 0x0A;
const RESP_DIRECT_MSG_RECV     = 0x07;
const RESP_CHANNEL_MSG_RECV    = 0x08;
const RESP_DIRECT_MSG_RECV_V3  = 0x10;
const RESP_CHANNEL_MSG_RECV_V3 = 0x11;
const RESP_CHANNEL_INFO        = 0x12;
const CMD_ENCRYPTED_DM         = 0x90;
const CMD_UNKNOWN              = 0x77;

function u32le(n)
{
    return chr(n & 0xFF) + chr((n >> 8) & 0xFF) + chr((n >> 16) & 0xFF) + chr((n >> 24) & 0xFF);
}

function fillBytes(byte, count)
{
    let out = "";
    for (let i = 0; i < count; i++) out += chr(byte);
    return out;
}

function directPayload(from, to, text)
{
    return u32le(from) + u32le(to) + chr(length(text)) + text;
}

function groupPayload(from, slot, text)
{
    return u32le(from) + chr(slot) + text;
}

// ---- 1. Single complete direct response frame decodes through accumulator
api._test_reset();
{
    const payload = directPayload(0x11223344, 0x55667788, "hello mesh");
    const frame = api._test_build_frame(RESP_DIRECT_MSG_RECV, payload);
    const frames = api._test_inject(frame, STRICT_ON);
    check("single frame: count", length(frames), 1);
    check("single frame: cmd",   frames[0]?.cmd, RESP_DIRECT_MSG_RECV);
    check("single frame: payload length", length(frames[0]?.payload), length(payload));
}

// ---- 2. Fragmented stock frame across 3 reads
api._test_reset();
{
    const payload = groupPayload(0xDEADBEEF, 3, "fragment me");
    const frame   = api._test_build_frame(RESP_CHANNEL_MSG_RECV, payload);
    const a = substr(frame, 0, 2);
    const b = substr(frame, 2, 5);
    const c = substr(frame, 7);

    check("fragmented: read 1 yields nothing", length(api._test_inject(a, STRICT_ON)), 0);
    check("fragmented: read 2 yields nothing", length(api._test_inject(b, STRICT_ON)), 0);
    const f = api._test_inject(c, STRICT_ON);
    check("fragmented: read 3 completes", length(f), 1);
    check("fragmented: cmd correct",      f[0]?.cmd, RESP_CHANNEL_MSG_RECV);
}

// ---- 3. Oversize kill switch, little-endian length claim
api._test_reset();
{
    const hdr = chr(0x3E) + chr(0x60) + chr(0xEA);  // claim 60000 byte payload
    const frames = api._test_inject(hdr, STRICT_ON);
    check("oversize: zero frames emitted", length(frames), 0);
    check("oversize: stat incremented", api._test_stats().early_drop_oversize, 1);
}

// ---- 4. Boundary: 257 is rejected
api._test_reset();
{
    const hdr = chr(0x3E) + chr(0x01) + chr(0x01);  // 257
    api._test_inject(hdr, STRICT_ON);
    check("boundary 257: rejected", api._test_stats().early_drop_oversize, 1);
}

// ---- 5. Encrypted early-drop under strict mode
api._test_reset();
{
    const enc = api._test_build_frame(CMD_ENCRYPTED_DM, fillBytes(0x58, 32));
    check("encrypted: dropped", length(api._test_inject(enc, STRICT_ON)), 0);
    check("encrypted: stat incremented", api._test_stats().early_drop_encrypted, 1);
}

// ---- 6. Encrypted frames with strict OFF -> unknown gate
api._test_reset();
{
    const enc = api._test_build_frame(CMD_ENCRYPTED_DM, fillBytes(0x58, 16));
    api._test_inject(enc, STRICT_OFF);
    check("encrypted strict-off: not counted as encrypted drop", api._test_stats().early_drop_encrypted, 0);
    check("encrypted strict-off: ignored as known non-message", api._test_stats().early_drop_unknown_cmd, 0);
}

// ---- 7. Unknown command early-drop
api._test_reset();
{
    const f = api._test_build_frame(CMD_UNKNOWN, "junk-payload");
    check("unknown cmd: dropped", length(api._test_inject(f, STRICT_ON)), 0);
    check("unknown cmd: stat incremented", api._test_stats().early_drop_unknown_cmd, 1);
}

// ---- 8. Message waiting tickle triggers no emitted Crow message
api._test_reset();
{
    const tickle = api._test_build_frame(PUSH_CODE_MSG_WAITING, "");
    check("message waiting: no message emitted", length(api._test_inject(tickle, STRICT_ON)), 0);
    check("message waiting: stat incremented", api._test_stats().message_waiting, 1);
}

// ---- 9. Pre-frame garbage triggers resync
api._test_reset();
{
    const garbage = "\x00\x01\x02\x99\xAA\xBB";
    const payload = directPayload(0xABCDEF01, 0, "after garbage");
    const frame   = api._test_build_frame(RESP_DIRECT_MSG_RECV, payload);
    const frames  = api._test_inject(garbage + frame, STRICT_ON);
    check("resync: one frame after garbage", length(frames), 1);
    checkTrue("resync: stat incremented", api._test_stats().resync_skips >= 1);
}

// ---- 10. Back-to-back frames
api._test_reset();
{
    const p1 = directPayload(1, 2, "one");
    const p2 = directPayload(3, 4, "two");
    const buf = api._test_build_frame(RESP_DIRECT_MSG_RECV, p1)
              + api._test_build_frame(RESP_DIRECT_MSG_RECV, p2);
    check("back-to-back: 2 frames", length(api._test_inject(buf, STRICT_ON)), 2);
}

// ---- 11. Multi-read oversize drain recovers to next valid frame
api._test_reset();
{
    api._test_inject(chr(0x3E) + chr(0x00) + chr(0x04), STRICT_ON); // claim 1024
    api._test_inject(fillBytes(0xAA, 600), STRICT_ON);
    api._test_inject(fillBytes(0xAA, 424), STRICT_ON);
    const good = api._test_build_frame(RESP_DIRECT_MSG_RECV, directPayload(7, 8, "ok"));
    const f = api._test_inject(good, STRICT_ON);
    check("oversize drain: next valid frame parses", length(f), 1);
    check("oversize drain: cmd correct", f[0]?.cmd, RESP_DIRECT_MSG_RECV);
}

// ---- 12. Malformed direct text — length byte exceeds plen
api._test_reset();
{
    const evil = u32le(1) + u32le(2) + chr(99) + "abc";
    const frame = api._test_build_frame(RESP_DIRECT_MSG_RECV, evil);
    check("malformed: dropped", length(api._test_inject(frame, STRICT_ON)), 0);
    check("malformed: stat incremented", api._test_stats().early_drop_malformed_text, 1);
}

// ---- 13. Decoder: older direct response produces correct Crow msg shape
api._test_reset();
{
    const payload = directPayload(0xCAFEBABE, 0x00000000, "hi");
    const msg = api._test_decode(RESP_DIRECT_MSG_RECV, payload);
    check("decode direct: transport", msg?.transport, "meshcore");
    check("decode direct: backend",   msg?.backend,   "tcp_api");
    check("decode direct: from",      msg?.from,      0xCAFEBABE);
    check("decode direct: to",        msg?.to,        0);
    check("decode direct: text",      msg?.data?.text_message, "hi");
    check("decode direct: not group", msg?.metadata?.is_group_message, false);
    check("decode direct: unverified accepted", msg?.metadata?.local_direct, true);
    check("decode direct: identity unverified", msg?.metadata?.direct_identity_verified, false);
    check("decode direct: unverified stat", api._test_stats().direct_identity_unverified, 1);
}

// ---- 13b. Decoder: legacy direct destination is verified when self id is known
api._test_reset();
{
    api._test_set_self_public_key_prefix(u32le(0x55667788) + "\x00\x00");
    const match = api._test_decode(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0x55667788, "for me"));
    const mismatch = api._test_decode(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0x11111111, "not me"));
    check("decode direct: verified match accepted", match?.metadata?.local_direct, true);
    check("decode direct: verified match marked", match?.metadata?.direct_identity_verified, true);
    check("decode direct: verified mismatch not local", mismatch?.metadata?.local_direct, false);
    check("decode direct: verified mismatch marked", mismatch?.metadata?.direct_identity_verified, true);
    check("decode direct: verified stat", api._test_stats().direct_identity_verified, 2);
    check("decode direct: mismatch stat", api._test_stats().direct_identity_mismatch, 1);
}

// ---- 13c. Decoder: verified legacy direct handles ids with high bit set
api._test_reset();
{
    api._test_set_self_public_key_prefix(u32le(0xF5667788) + "\x00\x00");
    const msg = api._test_decode(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0xF5667788, "high id"));
    check("decode direct: high-bit id accepted", msg?.metadata?.local_direct, true);
    check("decode direct: high-bit id verified", msg?.metadata?.direct_identity_verified, true);
    check("decode direct: high-bit verified stat", api._test_stats().direct_identity_verified, 1);
}

// ---- 13d. Decoder: verified legacy direct handles zero-valued self id
api._test_reset();
{
    api._test_set_self_public_key_prefix(u32le(0) + "\x00\x00");
    const msg = api._test_decode(RESP_DIRECT_MSG_RECV, directPayload(0xCAFEBABE, 0, "zero id"));
    check("decode direct: zero self id accepted", msg?.metadata?.local_direct, true);
    check("decode direct: zero self id verified", msg?.metadata?.direct_identity_verified, true);
    check("decode direct: zero self id stat", api._test_stats().direct_identity_verified, 1);
}

// ---- 14. Decoder: older group response marks group metadata
api._test_reset();
{
    api._test_set_local_channels([{ namekey: "TacNet AQ==" }]);
    check("group setup: exact radio/Crow channel mapped", api._test_set_discovered_channel(5, "TacNet AQ=="), true);
    const payload = groupPayload(0xDEADBEEF, 5, "yo");
    const msg = api._test_decode(RESP_CHANNEL_MSG_RECV, payload);
    check("decode group: is_group", msg?.metadata?.is_group_message, true);
    check("decode group: slot", msg?.group_slot, 5);
    check("decode group: exact namekey", msg?.namekey, "TacNet AQ==");
    check("decode group: text", msg?.data?.text_message, "yo");
    check("group send: exact channel allowed", api._test_channel_send_allowed(5, "TacNet AQ=="), true);
}

// ---- 14b. Group receive/send stay disabled for name/key or slot mismatches
api._test_reset();
{
    api._test_set_local_channels([{ namekey: "TacNet AQ==" }]);
    check("group mismatch: wrong radio key not mapped", api._test_set_discovered_channel(5, "TacNet Ag=="), false);
    check("group mismatch: receive dropped", api._test_decode(RESP_CHANNEL_MSG_RECV, groupPayload(1, 5, "wrong key")), null);
    check("group mismatch: send blocked", api._test_channel_send_allowed(5, "TacNet AQ=="), false);

    check("group mismatch: wrong radio slot not mapped", api._test_set_discovered_channel(4, "TacNet AQ=="), true);
    check("group mismatch: receive wrong slot dropped", api._test_decode(RESP_CHANNEL_MSG_RECV, groupPayload(1, 5, "wrong slot")), null);
    check("group mismatch: send wrong slot blocked", api._test_channel_send_allowed(5, "TacNet AQ=="), false);
}

// ---- 15. Decoder: v3 direct and group response codes are accepted
api._test_reset();
{
    api._test_set_local_channels([{ namekey: "V3 AQ==" }]);
    api._test_set_discovered_channel(2, "V3 AQ==");
    const d = api._test_decode(RESP_DIRECT_MSG_RECV_V3, directPayload(1, 2, "v3d"));
    const g = api._test_decode(RESP_CHANNEL_MSG_RECV_V3, groupPayload(3, 2, "v3g"));
    check("decode v3 direct: text", d?.data?.text_message, "v3d");
    check("decode v3 group: text", g?.data?.text_message, "v3g");
}

// ---- 16. Channel info response is cached for discovery/control
api._test_reset();
{
    const response = chr(RESP_CHANNEL_INFO) + chr(0) + ("TacNet" + fillBytes(0, 26)) + fillBytes(1, 16);
    const frame = chr(0x3E) + chr(length(response) & 0xFF) + chr((length(response) >> 8) & 0xFF) + response;
    check("channel info: no Crow message emitted", length(api._test_inject(frame, STRICT_ON)), 0);
    check("channel info: cached stat", api._test_stats().responses_cached, 1);
    const cached = api._test_take_response(RESP_CHANNEL_INFO);
    check("channel info: cached cmd", cached?.cmd, RESP_CHANNEL_INFO);
    check("channel info: cached payload length", length(cached?.payload), 50);
}

// ---- 17. Client-to-radio command frame uses '<' and little-endian length
api._test_reset();
{
    const cmd = api._test_build_command(CMD_SYNC_NEXT_MESSAGE, "");
    check("command marker", ord(cmd, 0), 0x3C);
    check("command length LSB", ord(cmd, 1), 1);
    check("command length MSB", ord(cmd, 2), 0);
    check("command payload code", ord(cmd, 3), CMD_SYNC_NEXT_MESSAGE);
}

// ---- 18. TX payloads are shared by TCP and USB transports
{
    const direct = api._test_build_direct_send("ABCDEF", "hello", 2);
    check("direct tx marker", ord(direct, 0), 0x3C);
    check("direct tx command", ord(direct, 3), 0x02);
    check("direct tx text type", ord(direct, 4), 0x00);
    check("direct tx retry", ord(direct, 5), 2);
    check("direct tx prefix", substr(direct, 10, 6), "ABCDEF");

    const channel = api._test_build_channel_send(4, "hello");
    check("channel tx marker", ord(channel, 0), 0x3C);
    check("channel tx command", ord(channel, 3), 0x03);
    check("channel tx text type", ord(channel, 4), 0x00);
    check("channel tx slot", ord(channel, 5), 4);
    check("channel tx text", substr(channel, 10), "hello");
}

// ---- 19. USB app-start profiles use valid Companion command framing
{
    const zeros = api._test_app_start_payload_profile("crow_zeros");
    const cli = api._test_app_start_payload_profile("meshcore_cli");
    check("USB crow profile marker", ord(zeros, 0), 0x3C);
    check("USB crow profile payload", substr(zeros, 3), "\x01\x00\x00\x00\x00\x00\x00\x00Crow");
    check("USB CLI profile payload", substr(cli, 3), "\x01\x03      Crow");
}

printf("\n%d passed, %d failed\n", count - failures, failures);
exit(failures > 0 ? 1 : 0);
