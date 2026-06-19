#!/usr/bin/env ucode
// Tests for lora_outbound_text.uc (outbound LoRa text formatter).
// Run with: ucode -R -L .:./tests tests/test_outbound_formatter.uc
// Exits non-zero on any failure.

import * as fmt from "lora_outbound_text";

let failed = 0;
let passed = 0;

function check(name, actual, expected) {
    if (actual == expected) {
        printf("ok   - %s\n", name);
        passed++;
    } else {
        printf("FAIL - %s\n  expected: %J\n  actual:   %J\n", name, expected, actual);
        failed++;
    }
}

// --- gatewayTag ---
check("meshcore default idx 0 -> MCGW", fmt.gatewayTag("meshcore", 0), "MCGW");
check("meshcore idx 1 -> MCG2", fmt.gatewayTag("meshcore", 1), "MCG2");
check("meshcore idx 2 -> MCG3", fmt.gatewayTag("meshcore", 2), "MCG3");
check("meshtastic default idx 0 -> MTGW", fmt.gatewayTag("meshtastic", 0), "MTGW");
check("meshtastic idx 1 -> MTG1", fmt.gatewayTag("meshtastic", 1), "MTG1");
check("meshtastic idx 2 -> MTG2", fmt.gatewayTag("meshtastic", 2), "MTG2");
check("unknown transport -> MCGW fallback", fmt.gatewayTag("bogus", 0), "MCGW");
check("null gateway_index -> default 0", fmt.gatewayTag("meshcore", null), "MCGW");

// --- prepare: null guard ---
check("prepare(null) returns null", fmt.prepare(null, "meshcore", 0, 255), null);

// --- prepare: short message fits ---
let msg1 = { originating_callsign: "KN6ABC", data: { text_message: "hello" } };
check("short fits with header",
    fmt.prepare(msg1, "meshcore", 0, 255),
    "KN6ABC@MCGW> hello");

// --- prepare: callsign fallback chain ---
let msg2 = { callsign: "W1AW", data: { text_message: "hi" } };
check("callsign fallback (msg.callsign)",
    fmt.prepare(msg2, "meshtastic", 0, 255),
    "W1AW@MTGW> hi");

let msg3 = { from_callsign: "N0CALL", data: { text_message: "x" } };
check("callsign fallback (msg.from_callsign)",
    fmt.prepare(msg3, "meshcore", 1, 255),
    "N0CALL@MCG2> x");

let msg4 = { data: { callsign: "K6XYZ", text_message: "y" } };
check("callsign fallback (data.callsign)",
    fmt.prepare(msg4, "meshcore", 0, 255),
    "K6XYZ@MCGW> y");

let msg5 = { data: { text_message: "z" } };
check("callsign fallback UNKNOWN",
    fmt.prepare(msg5, "meshcore", 0, 255),
    "UNKNOWN@MCGW> z");

// --- prepare: missing text_message -> empty body ---
let msg6 = { originating_callsign: "KN6ABC", data: {} };
check("missing text_message -> just header",
    fmt.prepare(msg6, "meshcore", 0, 255),
    "KN6ABC@MCGW> ");

// --- prepare: truncation with ellipsis ---
// header "KN6ABC@MCGW> " = 13 chars; max=20 -> room=7; body="abcd..." (4 + "...")
let msg7 = { originating_callsign: "KN6ABC", data: { text_message: "abcdefghijklmno" } };
check("truncates with ellipsis when room > 3",
    fmt.prepare(msg7, "meshcore", 0, 20),
    "KN6ABC@MCGW> abcd...");

// --- prepare: truncation without ellipsis when room <= 3 ---
// header 13 chars; max=15 -> room=2; body=substr(text,0,2)="ab"
let msg8 = { originating_callsign: "KN6ABC", data: { text_message: "abcdefgh" } };
check("truncates without ellipsis when room <= 3",
    fmt.prepare(msg8, "meshcore", 0, 15),
    "KN6ABC@MCGW> ab");

// --- prepare: header exceeds payload budget -> returns truncated header ---
// header "KN6ABC@MCGW> " = 13 chars; max=5 -> room=-8; return substr(header,0,5)
let msg9 = { originating_callsign: "KN6ABC", data: { text_message: "anything" } };
check("header exceeds budget -> truncated header",
    fmt.prepare(msg9, "meshcore", 0, 5),
    "KN6AB");

// --- prepare: default max_payload (255) ---
let msg10 = { originating_callsign: "KN6ABC", data: { text_message: "default-budget" } };
check("default max_payload (null)",
    fmt.prepare(msg10, "meshcore", 0, null),
    "KN6ABC@MCGW> default-budget");

// --- prepare: exactly fits boundary ---
// header 13 + body 7 = 20
let msg11 = { originating_callsign: "KN6ABC", data: { text_message: "1234567" } };
check("exact fit at max_payload",
    fmt.prepare(msg11, "meshcore", 0, 20),
    "KN6ABC@MCGW> 1234567");

// --- summary ---
printf("\n%d passed, %d failed\n", passed, failed);
exit(failed > 0 ? 1 : 0);
