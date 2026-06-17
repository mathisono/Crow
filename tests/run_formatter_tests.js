#!/usr/bin/env node
// Node-side test runner for the outbound LoRa text formatter.
//
// Why this exists: the canonical formatter lives in lora_outbound_text.uc
// and the canonical tests live in tests/test_outbound_formatter.uc. The
// ucode interpreter is not always available in dev environments (CI, laptops
// without OpenWrt SDK). This file re-implements the formatter contract in JS
// from the .uc source and runs the same logical test cases so the behavior
// can be exercised with just Node.
//
// If `ucode` is on PATH, this runner will also invoke the .uc test file
// and surface its result.
//
// Run with: node tests/run_formatter_tests.js
// Exits non-zero on any failure.

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

// ---------- JS port of lora_outbound_text.uc ----------
const DEFAULT_LORA_MAX_PAYLOAD = 255;
const ELLIPSIS = '...';

function normTransport(t) {
    switch (t) {
        case 'meshcore':
        case 'meshcore_tnc':
            return 'meshcore';
        case 'meshtastic':
            return 'meshtastic';
        default:
            return t;
    }
}

function gatewayTag(target_transport, gateway_index) {
    const t = normTransport(target_transport);
    const idx = gateway_index ?? 0;
    switch (t) {
        case 'meshcore':
            return idx <= 0 ? 'MCGW' : `MCG${idx + 1}`;
        case 'meshtastic':
            return idx <= 0 ? 'MTGW' : `MTG${idx}`;
        default:
            return 'MCGW';
    }
}

function sourceCallsign(msg) {
    return msg.originating_callsign
        ?? msg.callsign
        ?? msg.from_callsign
        ?? msg.data?.callsign
        ?? 'UNKNOWN';
}

function prepare(msg, target_transport, gateway_index, max_payload) {
    if (!msg) return null;
    max_payload = max_payload ?? DEFAULT_LORA_MAX_PAYLOAD;
    const cleartext = msg.data?.text_message ?? '';
    const callsign = sourceCallsign(msg);
    const tag = gatewayTag(target_transport, gateway_index);
    const header = `${callsign}@${tag}> `;
    const room = max_payload - header.length;

    if (room <= 0) return header.substring(0, max_payload);

    if (cleartext.length > room) {
        const body = room > ELLIPSIS.length
            ? cleartext.substring(0, room - ELLIPSIS.length) + ELLIPSIS
            : cleartext.substring(0, room);
        return header + body;
    }
    return header + cleartext;
}

// ---------- tiny assert harness ----------
let passed = 0, failed = 0;
function check(name, actual, expected) {
    const ok = JSON.stringify(actual) === JSON.stringify(expected);
    if (ok) {
        console.log(`ok   - ${name}`);
        passed++;
    } else {
        console.log(`FAIL - ${name}`);
        console.log(`  expected: ${JSON.stringify(expected)}`);
        console.log(`  actual:   ${JSON.stringify(actual)}`);
        failed++;
    }
}

// ---------- cases (mirrors tests/test_outbound_formatter.uc) ----------
check('meshcore default idx 0 -> MCGW', gatewayTag('meshcore', 0), 'MCGW');
check('meshcore_tnc normalizes -> MCGW', gatewayTag('meshcore_tnc', 0), 'MCGW');
check('meshcore idx 1 -> MCG2', gatewayTag('meshcore', 1), 'MCG2');
check('meshcore idx 2 -> MCG3', gatewayTag('meshcore', 2), 'MCG3');
check('meshtastic default idx 0 -> MTGW', gatewayTag('meshtastic', 0), 'MTGW');
check('meshtastic idx 1 -> MTG1', gatewayTag('meshtastic', 1), 'MTG1');
check('meshtastic idx 2 -> MTG2', gatewayTag('meshtastic', 2), 'MTG2');
check('unknown transport -> MCGW fallback', gatewayTag('bogus', 0), 'MCGW');
check('null gateway_index -> default 0', gatewayTag('meshcore', null), 'MCGW');

check('prepare(null) returns null', prepare(null, 'meshcore', 0, 255), null);

check('short fits with header',
    prepare({ originating_callsign: 'KN6ABC', data: { text_message: 'hello' } }, 'meshcore', 0, 255),
    'KN6ABC@MCGW> hello');

check('callsign fallback (msg.callsign)',
    prepare({ callsign: 'W1AW', data: { text_message: 'hi' } }, 'meshtastic', 0, 255),
    'W1AW@MTGW> hi');

check('callsign fallback (msg.from_callsign)',
    prepare({ from_callsign: 'N0CALL', data: { text_message: 'x' } }, 'meshcore', 1, 255),
    'N0CALL@MCG2> x');

check('callsign fallback (data.callsign)',
    prepare({ data: { callsign: 'K6XYZ', text_message: 'y' } }, 'meshcore', 0, 255),
    'K6XYZ@MCGW> y');

check('callsign fallback UNKNOWN',
    prepare({ data: { text_message: 'z' } }, 'meshcore', 0, 255),
    'UNKNOWN@MCGW> z');

check('missing text_message -> just header',
    prepare({ originating_callsign: 'KN6ABC', data: {} }, 'meshcore', 0, 255),
    'KN6ABC@MCGW> ');

check('truncates with ellipsis when room > 3',
    prepare({ originating_callsign: 'KN6ABC', data: { text_message: 'abcdefghijklmno' } }, 'meshcore', 0, 20),
    'KN6ABC@MCGW> abcd...');

check('truncates without ellipsis when room <= 3',
    prepare({ originating_callsign: 'KN6ABC', data: { text_message: 'abcdefgh' } }, 'meshcore', 0, 15),
    'KN6ABC@MCGW> ab');

check('header exceeds budget -> truncated header',
    prepare({ originating_callsign: 'KN6ABC', data: { text_message: 'anything' } }, 'meshcore', 0, 5),
    'KN6AB');

check('default max_payload (null)',
    prepare({ originating_callsign: 'KN6ABC', data: { text_message: 'default-budget' } }, 'meshcore', 0, null),
    'KN6ABC@MCGW> default-budget');

check('meshcore_tnc target normalizes',
    prepare({ originating_callsign: 'K6T', data: { text_message: 'ok' } }, 'meshcore_tnc', 0, 255),
    'K6T@MCGW> ok');

check('exact fit at max_payload',
    prepare({ originating_callsign: 'KN6ABC', data: { text_message: '1234567' } }, 'meshcore', 0, 20),
    'KN6ABC@MCGW> 1234567');

// ---------- optional: run ucode tests if interpreter available ----------
let ucodeStatus = 'skipped (ucode not on PATH)';
const which = spawnSync('which', ['ucode']);
if (which.status === 0) {
    const repoRoot = path.resolve(__dirname, '..');
    const ucTest = path.join('tests', 'test_outbound_formatter.uc');
    if (fs.existsSync(path.join(repoRoot, ucTest))) {
        const r = spawnSync('ucode', ['-R', '-L', `${repoRoot}:${path.join(repoRoot, 'tests')}`, ucTest],
            { cwd: repoRoot, encoding: 'utf8' });
        process.stdout.write('\n--- ucode tests ---\n');
        process.stdout.write(r.stdout || '');
        process.stderr.write(r.stderr || '');
        ucodeStatus = r.status === 0 ? 'passed' : `failed (exit ${r.status})`;
        if (r.status !== 0) failed++;
    } else {
        ucodeStatus = 'skipped (test file missing)';
    }
}

console.log(`\nJS:    ${passed} passed, ${failed} failed`);
console.log(`ucode: ${ucodeStatus}`);
process.exit(failed > 0 ? 1 : 0);
