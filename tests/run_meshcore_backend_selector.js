#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

function check(name, got, want) {
    if (got === want) {
        console.log(`ok   - ${name}`);
        return 0;
    }
    console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`);
    return 1;
}

function ensureDefaultChannel(config, namekey, label) {
    if (!config.channels) config.channels = [];
    for (let i = 0; i < config.channels.length; i++) {
        if (config.channels[i].namekey === namekey) {
            config.channels[i].label = label;
            return;
        }
    }
    config.channels.push({ namekey, label });
}

function backendChoice(config) {
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    const serialMode = ['serial', 'serial-api', 'usb', 'usb-api'].includes(mode);
    const tcpMode = ['api', 'tcp', 'tcp-api', 'companion-api'].includes(mode);
    if (serialMode || ((config.meshcore_serial_api?.enabled || config.meshcore_usb_api?.enabled) && !config.meshcore_tcp_api?.enabled && !tcpMode && mode !== 'udp')) return 'serial';
    if (tcpMode || config.meshcore_tcp_api?.enabled) return 'tcp';
    if (config.meshcore && config.meshcore.enabled !== false && !serialMode) return 'udp';
    return null;
}

let failures = 0;

{
    const config = { channels: [], meshcore_tcp_api: { enabled: true } };
    ensureDefaultChannel(config, 'MeshCore izOH6cXN6mrJ5e26oRXNcg==', 'MeshCore~Public');
    failures += check('default public channel added', config.channels.length, 1);
    failures += check('public namekey', config.channels[0].namekey, 'MeshCore izOH6cXN6mrJ5e26oRXNcg==');
    failures += check('public label', config.channels[0].label, 'MeshCore~Public');
}

failures += check('USB serial selected', backendChoice({ meshcore_serial_api: { enabled: true } }), 'serial');
failures += check('TCP preferred over USB', backendChoice({
    meshcore_tcp_api: { enabled: true }, meshcore_serial_api: { enabled: true }
}), 'tcp');

console.log(`\n${failures === 0 ? 5 : 5 - failures} passed, ${failures} failed`);

const uc = spawnSync('ucode', [path.join(__dirname, 'test_meshcore_backend.uc')], { stdio: 'inherit' });
if (uc.error && uc.error.code !== 'ENOENT') {
    throw uc.error;
}
if (uc.error && uc.error.code === 'ENOENT') {
    console.log('ucode not found; skipped canonical .uc test');
}
else if (uc.status !== 0) {
    process.exit(uc.status);
}

process.exit(failures > 0 ? 1 : 0);
