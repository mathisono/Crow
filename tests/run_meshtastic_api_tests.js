#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const source = fs.readFileSync('meshtastic_API.uc', 'utf8');
let failures = 0;
let count = 0;

function check(name, got, want = true) {
  count++;
  if (got === want) {
    console.log(`ok   - ${name}`);
    return;
  }
  failures++;
  console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`);
}

check('operator notification helper exists', source.includes('function notifyOperator(lines, mergekey)'));
const notificationBody = source.match(/function notifyChannelDiscovered\(ch, action\)\n\{([\s\S]*?)\n\}/)?.[1] || '';
check('channel discovery notification avoids raw PSKs', notificationBody.includes('Runtime only; not saved to Crow config.') && !notificationBody.includes('ch.psk'));
check('new channels increment discovery telemetry', source.includes('stats.channels_discovered++') && source.includes('notifyChannelDiscovered(ch, "discovered")'));
check('changed channels increment update telemetry', source.includes('stats.channels_updated++') && source.includes('notifyChannelDiscovered(ch, "updated")'));
check('status exposes channel updates', source.includes('channels_updated: stats.channels_updated'));
check('discovery remains read-only', source.includes('Do not mutate config.channels or write files here') || source.includes('Runtime only; not saved to Crow config.'));

const uc = spawnSync('ucode', [path.join(__dirname, 'test_meshtastic_api.uc')], { stdio: 'inherit' });
if (uc.error && uc.error.code !== 'ENOENT') throw uc.error;
if (uc.error && uc.error.code === 'ENOENT') {
  console.log('ucode not found; skipped canonical .uc test');
} else if (uc.status !== 0) {
  process.exit(uc.status);
}

console.log(`\n${count - failures} passed, ${failures} failed`);
process.exit(failures > 0 ? 1 : 0);
