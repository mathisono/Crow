#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function selectStorageCandidate(candidates, label = 'CROWDATA') {
    for (const candidate of candidates) {
        if (candidate.label === label) return candidate;
    }
    return candidates.length === 1 ? candidates[0] : null;
}

let failures = 0;
function check(name, got, want) {
    if (got === want) {
        console.log(`ok   - ${name}`);
    } else {
        failures++;
        console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`);
    }
}

check('CROWDATA is preferred among multiple drives',
    selectStorageCandidate([{ device: '/dev/sda1' }, { device: '/dev/sdb1', label: 'CROWDATA' }]).device,
    '/dev/sdb1');
check('one unlabeled removable drive is accepted',
    selectStorageCandidate([{ device: '/dev/sda1' }]).device, '/dev/sda1');
check('ambiguous unlabeled drives are refused',
    selectStorageCandidate([{ device: '/dev/sda1' }, { device: '/dev/sdb1' }]), null);

const root = path.join(__dirname, '..');
const commands = fs.readFileSync(path.join(root, 'commands.uc'), 'utf8');
const platform = fs.readFileSync(path.join(root, 'platforms', 'aredn', 'platform.uc'), 'utf8');
const helper = fs.readFileSync(path.join(root, 'platforms', 'aredn', 'usb-setup.sh'), 'utf8');

check('GUI command exposes /storage assimilate',
    commands.includes('case "assimilate":') && commands.includes('platform.storageAssimilate()'), true);
check('GUI help explicitly says assimilate never formats',
    commands.includes('existing USB data drive (never formats)'), true);
check('platform exports assimilation API',
    platform.includes('storageAssimilate,'), true);
check('assimilation runs support discovery when no block candidate exists',
    platform.includes('`${setupArg} assimilate >${logArg} 2>&1`'), true);
check('storage mount accepts the selected safe device',
    platform.includes('function storageMount(requestedDevice)') && platform.includes('requestedDevice ?? storageDevice'), true);
check('scan reports label and filesystem metadata',
    platform.includes('label: info.LABEL') && platform.includes('filesystem: info.TYPE'), true);
check('helper supports both current apk and legacy opkg firmware',
    helper.includes('command -v apk') && helper.includes('command -v opkg'), true);
check('assimilate loads the USB mass-storage stack',
    helper.includes('scsi_mod sd_mod usb_storage uas'), true);
check('reprobe is restricted to USB mass-storage class',
    helper.includes('= "08"') && helper.includes('Do not reset serial/GPS interfaces'), true);
check('formatting remains gated behind explicit format mode',
    helper.includes('if [ "$MODE" = "format" ]; then') && !helper.includes('if [ "$MODE" = "assimilate" ]; then\n    target='), true);
check('verified USB image migration releases the tmpfs copy',
    platform.includes('dstInfo.size === srcInfo.size') && platform.includes('fs.unlink(src)'), true);
check('degraded image cache uses bounded RAM limit',
    platform.includes('storageState === "usb" ? storageImageQuota : maxBinarySize'), true);
check('hotplug persistence follows assimilated drive UUID and actual label',
    platform.includes('function installStorageHotplug(device)') &&
    platform.includes('installStorageHotplug(device)') &&
    platform.includes('join("|", matchPatterns)') &&
    platform.includes('NORMALIZED="$(printf'), true);

const total = 16;
console.log(`\n${total - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
