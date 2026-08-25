// Canonical ucode checks for meshcore_serial_api.uc parser and frame builders.

import * as api from "meshcore_serial_api";

const RESP_DIRECT = 0x07;
const RESP_GROUP = 0x08;
const PUSH_WAITING = 0x83;
const CMD_SYNC_NEXT = 0x0a;

let failures = 0;
let count = 0;

function check(name, actual, expected)
{
    count++;
    if (actual === expected) {
        printf("ok   - %s\n", name);
    }
    else {
        failures++;
        printf("FAIL - %s (got %J, expected %J)\n", name, actual, expected);
    }
}

function u32(n)
{
    return chr(n & 0xff) + chr((n >> 8) & 0xff) + chr((n >> 16) & 0xff) + chr((n >> 24) & 0xff);
}

function directPayload(from, to, text)
{
    // Six-byte contact key prefix, path length, plain-text type, timestamp.
    return u32(from) + "\xaa\xbb" + chr(0xff) + chr(0) + u32(0x55667788) + text;
}

function groupPayload(from, slot, text)
{
    // Channel frames carry channel slot, path length, type and timestamp;
    // they do not carry an originating node-id.
    return chr(slot) + chr(0xff) + chr(0) + u32(0x11223344) + text;
}

const strictOn = { isEnabled: function () { return true; } };

api._test_reset();
{
    const frame = api._test_build_frame(RESP_DIRECT, directPayload(1, 2, "hello"));
    check("direct serial frame held while fragmented", length(api._test_inject(substr(frame, 0, 2), strictOn)), 0);
    check("direct serial frame completed", length(api._test_inject(substr(frame, 2), strictOn)), 1);
    const msg = api._test_decode(RESP_DIRECT, directPayload(1, 2, "hello"));
    check("serial direct preserves six-byte source prefix", length(msg?.from), 12);
    check("serial direct timestamp", msg?.sender_timestamp, 0x55667788);
    check("serial direct text", msg?.data?.text_message, "hello");
}

api._test_reset();
{
    const frame = api._test_build_frame(RESP_GROUP, groupPayload(3, 4, "group"));
    const frames = api._test_inject("\x00\x01" + frame, strictOn);
    check("serial resync decodes group", length(frames), 1);
    const msg = api._test_decode(frames[0].cmd, frames[0].payload);
    check("serial group backend tag", msg?.backend, "serial_api");
    check("serial group slot", msg?.group_slot, 4);
    check("serial group timestamp", msg?.sender_timestamp, 0x11223344);
}

api._test_reset();
{
    const payload = "\xf8\x00\x00" + groupPayload(0, 5, "v3 group");
    const frames = api._test_inject(api._test_build_frame(0x11, payload), strictOn);
    const msg = api._test_decode(frames[0].cmd, frames[0].payload);
    check("serial v3 group skips SNR prefix", msg?.group_slot, 5);
    check("serial v3 group text", msg?.data?.text_message, "v3 group");
}

api._test_reset();
{
    api._test_inject(chr(0x3e) + chr(0x01) + chr(0x01), strictOn);
    check("serial oversize rejected", api._test_stats().early_drop_oversize, 1);
}

api._test_reset();
{
    api._test_inject(api._test_build_frame(PUSH_WAITING, ""), strictOn);
    check("message waiting stat incremented", api._test_stats().message_waiting, 1);
}

{
    const frame = api._test_build_group_send({ rx_time: 0x11223344, data: { text_message: "out" } }, 2);
    check("group tx uses < marker", ord(frame, 0), 0x3c);
    check("group tx command", ord(frame, 3), 0x03);
    check("group tx slot", ord(frame, 5), 2);
}

printf("\n%d passed, %d failed\n", count - failures, failures);
exit(failures > 0 ? 1 : 0);
