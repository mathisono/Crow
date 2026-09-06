#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const ui = fs.readFileSync(path.join(root, 'ui', 'ui.js'), 'utf8');
const css = fs.readFileSync(path.join(root, 'ui', 'ui.css'), 'utf8');
const event = fs.readFileSync(path.join(root, 'event.uc'), 'utf8');
const commands = fs.readFileSync(path.join(root, 'commands.uc'), 'utf8');
const meshcore = fs.readFileSync(path.join(root, 'meshcore_backend.uc'), 'utf8');
const tcp = fs.readFileSync(path.join(root, 'meshcore_tcp_api.uc'), 'utf8');
const serial = fs.readFileSync(path.join(root, 'meshcore_serial_api.uc'), 'utf8');
let failures = 0;

function check(name, value) {
    if (!value) {
        console.error('FAIL ' + name);
        failures++;
    }
    else {
        console.log('ok   ' + name);
    }
}

function disconnected(state) {
    return !!state && state !== 'connected' && state !== 'listening';
}

check('connected backend is not marked disconnected', !disconnected('connected'));
check('listening multicast backend is not marked disconnected', !disconnected('listening'));
check('missing socket is marked disconnected', disconnected('enabled-no-socket'));
check('handshake in progress is marked disconnected', disconnected('connecting'));
check('missing serial device is marked disconnected', disconnected('missing-device'));

check('channel payload includes backend binding and status',
    event.includes('backend_family: binding?.family') &&
    event.includes('backend_key: binding?.key') &&
    event.includes('backend_status: commands.backendStatusSnapshot()'));
check('ucode backend status exports have declaration terminators',
    /export function backendStatusSnapshot\(\)[\s\S]*?\n\};/.test(commands) &&
    /export function channelBackendBinding\(c\)[\s\S]*?\n\};/.test(commands));
check('keepalive refreshes backend health',
    event.includes('event: "beat", backend_status: commands.backendStatusSnapshot()'));
check('MeshCore slot channels bind to the active MeshCore backend',
    commands.includes('channel.isMeshcoreSlotChannel(c?.namekey)') &&
    commands.includes('meshcore.\${name}'));
check('GUI renders the compact disconnected overlay',
    ui.includes('function channelBackendDisconnected(channel)') &&
    ui.includes('function channelBackendReadout(channel)') &&
    ui.includes('class="backend-disconnected ${backendReadout.pending') &&
    ui.includes('status.state !== "connected" && status.state !== "listening"'));
check('GUI readout distinguishes connection attempts from device failures',
    ui.includes('CONNECTING TO DEVICE') &&
    ui.includes('RECONNECTING TO DEVICE') &&
    ui.includes("CAN'T CONNECT TO DEVICE") &&
    ui.includes('status.error || state.replace(/-/g, " ")'));
check('backend snapshot supplies device failure detail to the GUI',
    commands.includes('device: b.device ?? ""') &&
    commands.includes('error: b.last_error ?? ""') &&
    meshcore.includes('last_error: detail.last_error'));
check('GUI refreshes the overlay from heartbeat state',
    ui.includes('case "beat":') &&
    ui.includes('updateBackendStatuses(msg.backend_status)'));
check('overlay does not increase channel row footprint',
    css.includes('.channel .backend-disconnected') &&
    css.includes('position: absolute;') &&
    css.includes('inset: 0;') &&
    css.includes('font-size: 11px;'));
check('TCP Companion state requires current self-info',
    tcp.includes('let connectionReady = false;') &&
    tcp.includes('connectionReady = true;') &&
    tcp.includes('connectionReady ? "connected" : "connecting"'));
check('direct serial state waits for Companion self-info',
    serial.includes('serialState = "connecting";') &&
    serial.includes('companionReady = true;') &&
    serial.includes('serialState = "connected";'));

if (failures) {
    console.error('\n' + failures + ' backend disconnect UI test(s) failed');
    process.exit(1);
}
console.log('\nBackend disconnect UI checks passed');
