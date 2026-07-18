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

let failures = 0;

{
    const config = { channels: [], meshcore_tcp_api: { enabled: true } };
    ensureDefaultChannel(config, 'MeshCore izOH6cXN6mrJ5e26oRXNcg==', 'MeshCore~Public');
    failures += check('default public channel added', config.channels.length, 1);
    failures += check('public namekey', config.channels[0].namekey, 'MeshCore izOH6cXN6mrJ5e26oRXNcg==');
    failures += check('public label', config.channels[0].label, 'MeshCore~Public');
}

console.log(`\n${failures === 0 ? 3 : 3 - failures} passed, ${failures} failed`);

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
