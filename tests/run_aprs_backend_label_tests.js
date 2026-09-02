#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function backendTypeLabel(type) {
    switch (type ?? 'aprsis') {
        case 'aprsis': return 'aprs-is';
        case 'kiss_tcp': return 'aprs-kiss';
        case 'tcp_text':
        case 'xastir':
        case 'yaac': return 'aprs-tnc';
        default: return 'aprs';
    }
}

function normcall(value) {
    return String(value ?? '').trim().toUpperCase();
}

function makeBackendDisplayName(name, config, callsign) {
    const backend = `${backendTypeLabel(config?.type)}[${name}]`;
    callsign = normcall(callsign);
    return callsign ? `${backend} ${callsign}` : backend;
}

function check(name, got, want) {
    if (got === want) {
        console.log(`ok   - ${name}`);
        return 0;
    }
    console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`);
    return 1;
}

let failures = 0;
failures += check(
    'Xastir label includes configured callsign',
    makeBackendDisplayName('xastir_dzb4', { type: 'tcp_text' }, 'KJ6DZB-10'),
    'aprs-tnc[xastir_dzb4] KJ6DZB-10'
);
failures += check(
    'APRS-IS label normalizes configured callsign',
    makeBackendDisplayName('default', { type: 'aprsis' }, ' kj6dzb-10 '),
    'aprs-is[default] KJ6DZB-10'
);
failures += check(
    'KISS label includes configured callsign',
    makeBackendDisplayName('tnc', { type: 'kiss_tcp' }, 'KJ6DZB-10'),
    'aprs-kiss[tnc] KJ6DZB-10'
);
failures += check(
    'missing callsign preserves legacy label',
    makeBackendDisplayName('default', { type: 'aprsis' }, ''),
    'aprs-is[default]'
);

const source = fs.readFileSync(path.join(__dirname, '..', 'aprs.uc'), 'utf8');
failures += check(
    'production instance receives APRS callsign',
    source.includes('createBackendInstance(name, backendsCfg[name], cfg.callsign)'),
    true
);
failures += check(
    'channel mapping key remains backend config key',
    source.includes('push(out, { key: name, label: backends[name].displayName })'),
    true
);

const total = 6;
console.log(`\n${total - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
