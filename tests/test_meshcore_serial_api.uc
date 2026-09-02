// Canonical ucode checks for the USB Companion backend.
//
// These checks prove the software gate only.  A physical tagged RF message
// must still be observed through Crow before inbound RF is declared proven.

import * as api from "../meshcore_serial_api.uc";

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
    printf("FAIL - %s\n   got: %s\n   want: %s\n", name, got, want);
}

function checkTrue(name, got)
{
    check(name, !!got, true);
}

function fillBytes(byte, n)
{
    let out = "";
    for (let i = 0; i < n; i++) out += chr(byte);
    return out;
}

function groupPayload(slot, text)
{
    return chr(slot) + chr(0xff) + chr(0x00) +
        chr(0x44) + chr(0x33) + chr(0x22) + chr(0x11) + text;
}

function channelInfoPayload(index, name, secret)
{
    let padded = name;
    while (length(padded) < 32) padded += chr(0);
    return chr(0x12) + chr(index) + padded + secret + fillBytes(0, 2);
}

function channelDataPayload(slot, dataType, text)
{
    return chr(0) + chr(0) + chr(0) + chr(slot) + chr(0) +
        chr(dataType & 0xFF) + chr((dataType >> 8) & 0xFF) + chr(length(text)) + text;
}

global.DEBUG0 = function (...args) {};
global.DEBUG1 = function (...args) {};

const STRICT_ON = { isEnabled: function () { return true; } };
const RESP_CHANNEL_MSG_RECV = 0x08;
const RESP_CHANNEL_DATA_RECV = 0x1B;
const PUSH_MSG_WAITING = 0x83;

const PUBLIC_SECRET = "\x8b\x33\x87\xe9\xc5\xcd\xea\x6a\xc9\xe5\xed\xba\xa1\x15\xcd\x72";

// Explicitly configured slots authorize the matching Crow channel.
api._test_reset();
const publicInfo = api._test_decode_channel_info(channelInfoPayload(0, "Public", PUBLIC_SECRET));
check("Companion Public maps to Crow public channel", publicInfo?.namekey, "MeshCore izOH6cXN6mrJ5e26oRXNcg==");
api._test_set_local_channels([{ namekey: "TacNet AQ==" }]);
check("unverified slot rejects receive", api._test_channel_receive_allowed(5, "TacNet AQ=="), false);
check("unverified group frame is dropped", api._test_decode(RESP_CHANNEL_MSG_RECV, groupPayload(5, "before proof")), null);
check("unverified receive is counted", api._test_stats().group_receive_unverified, 1);

// A discovered but mismatched name/key also fails closed.
check("wrong radio key fails exact match", api._test_set_discovered_channel(5, "TacNet Ag=="), false);
check("wrong key remains blocked", api._test_channel_receive_allowed(5, "TacNet AQ=="), false);

// The same tuple on a different slot does not authorize the configured slot.
check("same tuple on wrong slot is recorded", api._test_set_discovered_channel(4, "TacNet AQ=="), true);
check("wrong slot remains blocked", api._test_channel_receive_allowed(5, "TacNet AQ=="), false);

// Only the exact configured name/key/slot tuple enables routing.
check("exact radio/Crow tuple is verified", api._test_set_discovered_channel(5, "TacNet AQ=="), true);
const msg = api._test_decode(RESP_CHANNEL_MSG_RECV, groupPayload(5, "tagged RF"));
check("verified group frame decodes", msg?.data?.text_message, "tagged RF");
check("verified group carries exact namekey", msg?.namekey, "TacNet AQ==");
check("verified slot permits send gate", api._test_channel_receive_allowed(5, "TacNet AQ=="), true);

// Channel datagrams are bounded and remain opt-in text; raw application data
// must not appear in Crow until its data type and exact channel tuple are set.
api._test_reset();
api._test_set_local_channels([{ namekey: "Data AQ==" }]);
check("channel data tuple is verified", api._test_set_discovered_channel(3, "Data AQ=="), true);
const datagram = channelDataPayload(3, 0xFFFF, "payload");
check("channel data disabled is unrouted", api._test_decode(RESP_CHANNEL_DATA_RECV, datagram), null);
check("channel data disabled counted", api._test_stats().channel_data_received, 1);
api._test_set_channel_data_text_types([0xFFFF]);
const dataMsg = api._test_decode(RESP_CHANNEL_DATA_RECV, datagram);
check("channel data enabled routes", dataMsg?.data?.text_message, "payload");
check("channel data metadata type", dataMsg?.metadata?.channel_data_type, 0xFFFF);
check("channel data routed counted", api._test_stats().channel_data_routed, 1);
check("channel data oversized rejected",
    api._test_decode(RESP_CHANNEL_DATA_RECV, channelDataPayload(3, 0xFFFF, fillBytes(0x78, 164))), null);

api._test_reset();
api._test_set_strict_direct_identity(true);
const modernDirect = "ABCDEF" + chr(0xff) + chr(0x00) +
    chr(0x44) + chr(0x33) + chr(0x22) + chr(0x11) + "no destination";
check("strict direct identity drops modern frame",
    api._test_decode(0x07, modernDirect), null);
check("strict direct identity drop is counted", api._test_stats().direct_identity_dropped, 1);
check("strict direct identity unverified is counted", api._test_stats().direct_identity_unverified, 1);

// Queue notification remains transport plumbing, not RF proof.
api._test_reset();
const waiting = api._test_build_frame(PUSH_MSG_WAITING, "");
check("queue push emits no Crow message", length(api._test_inject(waiting, STRICT_ON)), 0);
check("queue push is counted", api._test_stats().message_waiting, 1);

printf("\n%d/%d serial Companion ucode checks passed\n", count - failures, count);
if (failures > 0) exit(1);
