// Canonical ucode checks for Meshtastic TCP Port-API discovery.
//
// These tests cover read-only protobuf discovery and operator notification
// behavior. Hardware validation remains a separate release gate.

import * as api from "../meshtastic_API.uc";

let failures = 0;
let count = 0;
let queued = [];
let notified = [];

global.DEBUG0 = function (...args) {};
global.DEBUG1 = function (...args) {};
global.DEBUG2 = function (...args) {};
global.event = {
    queue: function (value) { push(queued, value); },
    notify: function (value, mergekey) { push(notified, { value: value, mergekey: mergekey }); }
};

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

function varint(value)
{
    let out = "";
    while (true) {
        let b = value & 0x7f;
        value = value >> 7;
        if (value) b |= 0x80;
        out += chr(b);
        if (!value) break;
    }
    return out;
}

function field(tag, value)
{
    return chr(tag) + varint(length(value)) + value;
}

function channelRecord(index, name, psk)
{
    const settings = field(0x1a, name) + field(0x22, psk);
    return chr(0x08) + varint(index) + field(0x12, settings);
}

function fromRadio(channel, configId)
{
    return field(0x52, channel) + chr(0x38) + varint(configId);
}

const psk = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10";
const packet = fromRadio(channelRecord(2, "Field", psk), 19);

api._test_reset_discovery();
queued = [];
notified = [];
check("discovery payload is recognized", api._test_process_discovered_channels(packet), true);
check("one channel is discovered", api._test_stats().channels_discovered, 1);
check("config completion is counted", api._test_stats().config_complete, 1);
check("one operator reply is queued", length(queued), 1);
check("one channels notification is emitted", length(notified), 1);
check("notification names the discovered index", queued[0].reply[1], "Index 2: Field");
check("notification is runtime-only", queued[0].reply[2], "Runtime only; not saved to Crow config.");
check("notification does not expose the PSK", queued[0].reply[1] === "Index 2: Field", true);

const changed = fromRadio(channelRecord(2, "Field", "\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20"), 20);
queued = [];
notified = [];
check("changed channel payload is recognized", api._test_process_discovered_channels(changed), true);
check("channel update is counted", api._test_stats().channels_updated, 1);
check("updated operator reply is queued", length(queued), 1);
check("updated notification names the channel", queued[0].reply[0], "<b>Meshtastic TCP API</b> updated channel");

printf("\n%d/%d Meshtastic API ucode checks passed\n", count - failures, count);
exit(failures > 0 ? 1 : 0);
