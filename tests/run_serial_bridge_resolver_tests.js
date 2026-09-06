#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const repo = path.join(__dirname, '..');
const resolver = path.join(repo, 'tools', 'crow-serial-bridge');
let failures = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        console.error('FAIL ' + name + ': expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
        failures++;
    }
    else {
        console.log('ok   ' + name);
    }
}

function fixture(devices, env = {}) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'crow-acm-test-'));
    const devRoot = path.join(root, 'dev');
    const ttyRoot = path.join(root, 'sys', 'class', 'tty');
    const usbRoot = path.join(root, 'sys', 'devices');
    fs.mkdirSync(devRoot, { recursive: true });
    fs.mkdirSync(ttyRoot, { recursive: true });
    fs.mkdirSync(usbRoot, { recursive: true });

    for (const d of devices) {
        fs.writeFileSync(path.join(devRoot, d.tty), '');
        const usb = path.join(usbRoot, d.tty);
        fs.mkdirSync(usb, { recursive: true });
        fs.writeFileSync(path.join(usb, 'idVendor'), d.vendor);
        fs.writeFileSync(path.join(usb, 'idProduct'), d.product);
        if (d.serial) fs.writeFileSync(path.join(usb, 'serial'), d.serial);
        const tty = path.join(ttyRoot, d.tty);
        fs.mkdirSync(tty, { recursive: true });
        fs.symlinkSync(usb, path.join(tty, 'device'));
    }

    const result = spawnSync('sh', [resolver, '--resolve'], {
        encoding: 'utf8',
        env: {
            ...process.env,
            CROW_SERIAL_TEST_MODE: '1',
            CROW_SERIAL_DEV_ROOT: devRoot,
            CROW_SERIAL_SYS_TTY_ROOT: ttyRoot,
            ...env
        }
    });
    fs.rmSync(root, { recursive: true, force: true });
    return {
        status: result.status,
        device: path.basename((result.stdout || '').trim())
    };
}

let r = fixture([
    { tty: 'ttyACM0', vendor: '1234', product: '0001', serial: 'OTHER' },
    { tty: 'ttyACM7', vendor: '239A', product: '8029', serial: 'MESH' }
], { CROW_SERIAL_USB_ID: '239a:8029' });
check('VID/PID selects the MeshCore device regardless of ACM number', r.device, 'ttyACM7');
check('VID/PID match exits successfully', r.status, 0);

r = fixture([
    { tty: 'ttyACM2', vendor: '239a', product: '8029', serial: 'WRONG' },
    { tty: 'ttyACM9', vendor: '9999', product: '0001', serial: 'RIGHT' }
], { CROW_SERIAL_USB_ID: '239a:8029', CROW_SERIAL_USB_SERIAL: 'RIGHT' });
check('serial identity takes precedence over VID/PID', r.device, 'ttyACM9');

r = fixture([
    { tty: 'ttyACM4', vendor: '1111', product: '2222', serial: 'SOLE' }
], { CROW_SERIAL_USB_ID: '239a:8029' });
check('sole ACM device is the safe fallback', r.device, 'ttyACM4');
check('sole fallback exits successfully', r.status, 0);

r = fixture([
    { tty: 'ttyACM0', vendor: '1111', product: '2222', serial: 'ONE' },
    { tty: 'ttyACM1', vendor: '3333', product: '4444', serial: 'TWO' }
], { CROW_SERIAL_USB_ID: '239a:8029' });
check('ambiguous non-matches are refused', r.status, 3);

r = fixture([], { CROW_SERIAL_USB_ID: '239a:8029' });
check('missing ACM device asks caller to retry', r.status, 2);

const source = fs.readFileSync(resolver, 'utf8');
check('runtime continuously rescans after hotplug/disconnect',
    source.includes('while :; do') &&
    source.includes('device=$(resolve_device)') &&
    source.includes('bridge exited rc=$rc; rescanning USB ACM devices'), true);

if (failures) {
    console.error('\n' + failures + ' serial bridge resolver test(s) failed');
    process.exit(1);
}
console.log('\nSerial bridge resolver checks passed');
