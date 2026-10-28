// Run with the inert dependencies produced by run_channel_join_tests.js.
// Never import the running service configuration or deliver its queued events.
import * as commands from "commands";

global.recorded = [];
global.event = { queue: e => push(recorded, e) };
global.DEBUG0 = function() {};

function check(ok, name)
{
    if (!ok) { die(`FAIL: ${name}\n`); }
    printf("PASS: %s\n", name);
}

function post(args)
{
    global.recorded = [];
    commands.post(args, "fixture", "AREDN og==");
    return filter(recorded, e => e.cmd === "newchannels");
}

let created = post(["join", "%Ops"]);
check(length(created) === 1 && created[0].channels[1].namekey === "%Ops og==", "short AREDN-only join reaches the real group handler");
check(created[0].channels[0].namekey === "AREDN og==" && created[0].channels[0].max === 150, "join preserves the existing channel and settings");

created = post(["join", "#Ops"]);
check(length(created) === 1 && length(b64dec(split(created[0].channels[1].namekey, " ")[1])) === 16, "shared-key join derives a 16-byte key");

created = post(["join", "AREDN"]);
check(length(created) === 0 && recorded[0].reply[0] === "Usage:", "plain default-channel name returns usage without replacing channels");

created = post(["join"]);
check(length(created) === 0 && recorded[0].reply[0] === "Usage:", "missing group name returns usage");

created = post(["channels", "join", "%Ops"]);
check(length(created) === 1 && created[0].channels[1].namekey === "%Ops og==", "long-form join remains compatible");

created = post(["channels", "join", "AREDN", "og=="]);
check(length(created) === 0, "existing default channel is not duplicated");
