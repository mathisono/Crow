#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
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

const meshcoreBackendSource = fs.readFileSync(path.join(__dirname, '..', 'meshcore_backend.uc'), 'utf8');
const meshcoreTcpSource = fs.readFileSync(path.join(__dirname, '..', 'meshcore_tcp_api.uc'), 'utf8');
const meshcoreSerialLoaderSource = fs.readFileSync(path.join(__dirname, '..', 'meshcore_serial_loader.uc'), 'utf8');
const meshcoreTcpLoaderSource = fs.readFileSync(path.join(__dirname, '..', 'meshcore_tcp_loader.uc'), 'utf8');
const meshcoreUdpLoaderSource = fs.readFileSync(path.join(__dirname, '..', 'meshcore_udp_loader.uc'), 'utf8');
const meshcoreDiscoveryLoaderSource = fs.readFileSync(path.join(__dirname, '..', 'meshcore_tcp_discovery_loader.uc'), 'utf8');
const meshtasticBackendSource = fs.readFileSync(path.join(__dirname, '..', 'meshtastic_backend.uc'), 'utf8');
const meshtasticProtoSource = fs.readFileSync(path.join(__dirname, '..', 'meshtasticprotobufs.uc'), 'utf8');
const meshtasticUdpLoaderSource = fs.readFileSync(path.join(__dirname, '..', 'meshtastic_udp_loader.uc'), 'utf8');
const meshtasticTcpLoaderSource = fs.readFileSync(path.join(__dirname, '..', 'meshtastic_tcp_loader.uc'), 'utf8');
const meshtasticProtoLoaderSource = fs.readFileSync(path.join(__dirname, '..', 'meshtasticprotobufs_loader.uc'), 'utf8');
const configSource = fs.readFileSync(path.join(__dirname, '..', 'config.uc'), 'utf8');
const eventSource = fs.readFileSync(path.join(__dirname, '..', 'event.uc'), 'utf8');
const uiSource = fs.readFileSync(path.join(__dirname, '..', 'ui', 'ui.js'), 'utf8');
failures += check('MeshCore backends are runtime-loaded',
    /^import \* as (udp|api|serialApi) from/m.test(meshcoreBackendSource), false);
failures += check('MeshCore selector has backend load boundary',
    meshcoreBackendSource.includes('require("meshcore_serial_loader")') &&
    meshcoreBackendSource.includes('require("meshcore_tcp_loader")') &&
    meshcoreBackendSource.includes('require("meshcore_udp_loader")') &&
    meshcoreSerialLoaderSource.includes('import * as backend from "meshcore_serial_api"') &&
    meshcoreTcpLoaderSource.includes('import * as backend from "meshcore_tcp_api"') &&
    meshcoreUdpLoaderSource.includes('import * as backend from "meshcore"'), true);
failures += check('TCP discovery is optional and separated',
    !/^import \* as .*meshcore_tcp_discovery/m.test(meshcoreTcpSource) &&
    meshcoreTcpSource.includes('require("meshcore_tcp_discovery_loader")') &&
    meshcoreDiscoveryLoaderSource.includes('import * as discovery from "meshcore_tcp_discovery"'), true);
failures += check('Meshtastic backends are runtime-loaded',
    !/^import \* as (udp|api) from/m.test(meshtasticBackendSource) &&
    meshtasticBackendSource.includes('require("meshtastic_udp_loader")') &&
    meshtasticBackendSource.includes('require("meshtastic_tcp_loader")') &&
    meshtasticUdpLoaderSource.includes('import * as backend from "meshtastic"') &&
    meshtasticTcpLoaderSource.includes('import * as backend from "meshtastic_API"'), true);
failures += check('Meshtastic protocol registry is explicit',
    meshtasticProtoSource.includes('export function setup(backend)') &&
    !meshtasticProtoSource.includes('import * as meshtastic from') &&
    !configSource.includes('import * as meshtasticprotobufs') &&
    meshtasticBackendSource.includes('require("meshtasticprotobufs_loader").setup(active)') &&
    meshtasticProtoLoaderSource.includes('import * as registry from "meshtasticprotobufs"'), true);

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
failures += check('MeshCore selector exports the active backend key',
    meshcoreBackendSource.includes('export function getBackendNames()') &&
    meshcoreBackendSource.includes('key: `meshcore.${activeName}`'), true);
failures += check('MeshCore selector label includes transport and configured callsign',
    meshcoreBackendSource.includes('const backend = `meshcore-${name}[${name}]`;') &&
    meshcoreBackendSource.includes('lastConfig?._configured_callsign ?? lastConfig?.callsign') &&
    meshcoreBackendSource.includes('`${backend} ${callsign}`'), true);
failures += check('configured callsign is retained before AREDN platform normalization',
    configSource.includes('config._configured_callsign = config.callsign;') &&
    configSource.indexOf('config._configured_callsign = config.callsign;') <
        configSource.indexOf('global.platform.mergePlatformConfig(config);'), true);
failures += check('channel payload includes MeshCore selector entries and resolved binding',
    eventSource.includes('meshcore_backends: meshcore_backend.getBackendNames') &&
    eventSource.includes('backend: c.backend || binding?.key || ""'), true);
failures += check('Configure Channels merges APRS and MeshCore backend options',
    uiSource.includes('let meshcoreBackends = [];') &&
    uiSource.includes('(aprsBackends || []).forEach(add);') &&
    uiSource.includes('(meshcoreBackends || []).forEach(add);') &&
    uiSource.includes('meshcoreBackends = msg.meshcore_backends;'), true);

const totalChecks = 15;
console.log(`\n${failures === 0 ? totalChecks : totalChecks - failures} passed, ${failures} failed`);

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
