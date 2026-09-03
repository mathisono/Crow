#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const build = fs.readFileSync(path.join(root, 'platforms/aredn/build.sh'), 'utf8');
const pre = fs.readFileSync(path.join(root, 'platforms/aredn/preupgrade'), 'utf8');
const post = fs.readFileSync(path.join(root, 'platforms/aredn/postupgrade'), 'utf8');

let passed = 0;
let failed = 0;

function ok(label, condition) {
  if (condition) {
    passed++;
    console.log(`ok   - ${label}`);
  } else {
    failed++;
    console.error(`FAIL - ${label}`);
  }
}

ok('APK pre-upgrade script is packaged',
  build.includes('platforms/aredn/preupgrade') && build.includes('$ROOT/data/.pre-upgrade'));
ok('APK pre-upgrade saves the live Crow config',
  pre.includes('cp -p /usr/local/crow/crow.conf /tmp/crow.conf.pre-upgrade'));
ok('APK post-upgrade restores the saved Crow config',
  post.includes('cp -p /tmp/crow.conf.pre-upgrade /usr/local/crow/crow.conf'));
ok('APK restoration happens before Crow restarts',
  post.indexOf('cp -p /tmp/crow.conf.pre-upgrade') < post.indexOf('/etc/init.d/crow restart'));
ok('IPK marks the live Crow config as a conffile',
  build.includes("'/usr/local/crow/crow.conf' > \"$ROOT/control/conffiles\""));

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
