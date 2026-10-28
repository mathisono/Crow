#!/usr/bin/env node
'use strict';

// Execute production storage functions, config updates, and the startup merge
// with inert hardware/filesystem adapters. The same fixture runs in native ucode.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const root = process.env.CROW_SOURCE_ROOT || path.resolve(__dirname, '..');
const configSource = fs.readFileSync(path.join(root, 'config.uc'), 'utf8');
const platformSource = fs.readFileSync(path.join(root, 'platforms/aredn/platform.uc'), 'utf8');
function extract(source, name, optional = false) {
    const match = source.match(new RegExp(`function ${name}\\([^)]*\\)\\n\\{[\\s\\S]*?^\\}`, 'm'));
    if (optional && !match) return '';
    assert.ok(match, `Missing production function ${name}`);
    return match[0];
}
const setup = extract(configSource, 'setup');
const start = setup.indexOf('    bconfig = json(');
const end = setup.indexOf('    config.update = update;');
assert.ok(start >= 0 && end > start, 'Missing startup configuration load/merge');
const [adapters, scenarios] = fs.readFileSync(path.join(__dirname, 'storage_persistence_fixture.uc'), 'utf8')
    .split('// PRODUCTION_FUNCTIONS');
assert.ok(adapters && scenarios, 'Missing fixture insertion point');
const fixture = `
const SCRIPT_NAME = "/usr/local/crow/crow.uc";
const CROW_USB_MOUNT = "/mnt/crow";
const CROW_USB_LABEL = "CROWDATA";
const CROW_USB_SETUP = "/usr/local/crow/platforms/aredn/usb-setup.sh";
const CROW_USB_ASSIMILATE_STATUS = "/tmp/crow-storage-assimilate.status";
const CROW_USB_ASSIMILATE_LOG = "/tmp/crow-storage-assimilate.log";
const DEFAULT_IMAGE_QUOTA = 64 * 1024 * 1024;
const DEFAULT_MIN_FREE = 16 * 1024 * 1024;
let bconfig, config, override, overrideWriteId = 0;
let storageConfig, storageMode, storageState, storageMountpoint, storageLabel;
let storageDevice, storageImageQuota, storageMinFree, storageReason;
${adapters}
${['localFile', 'readFirst', 'jsonEq', 'clone', 'writeOverride', 'updateStorage', 'update']
    .map(name => extract(configSource, name, name === 'updateStorage')).join('\n')}
${['setupStorage', 'selectStorageCandidate', 'saveStorageSettings', 'persistActiveStorage',
    'storageMount', 'assimilationFailureMessage', 'storageAssimilate', 'storageDisable']
    .map(name => extract(platformSource, name, ['saveStorageSettings', 'persistActiveStorage'].includes(name))).join('\n')}
// The platform captures this function in its returned API before setup assigns
// the same-named numeric quota variable. Keep that API binding separate here.
const setImageQuota = ${extract(platformSource, 'storageImageQuota').replace('function storageImageQuota(', 'function(')};
function reloadConfiguration() {
${setup.slice(start, end)}
    config.update = update;
    setupStorage(config);
}
${scenarios}
`;

if (process.argv.includes('--emit')) {
    process.stdout.write(fixture);
    process.exit(0);
}

const context = {
    type: value => value === null || value === undefined ? 'null' : Array.isArray(value) ? 'array' : typeof value,
    length: value => typeof value === 'string' ? Buffer.byteLength(value) : value?.length ?? 0,
    keys: Object.keys,
    json: JSON.parse,
    sprintf: (format, value) => JSON.stringify(value, null, format === '%.2J' ? 2 : undefined),
    time: () => 12345,
    match: (value, regex) => value.match(regex),
    push: (array, value) => array.push(value),
    substr: (value, start, count) => value.substr(start, count),
    index: (value, needle) => value.indexOf(needle),
    die: message => { throw new Error(message); },
    print: (...parts) => process.stdout.write(parts.join('')),
    printf: (format, count) => process.stdout.write(format.replace('%d', count))
};
vm.runInNewContext(fixture, context, {filename: 'storage-persistence-fixture.uc'});
const native = spawnSync(process.env.UCODE || 'ucode', ['-'], {input: fixture, encoding: 'utf8'});
if (native.error?.code === 'ENOENT') {
    console.log('SKIP: native storage persistence checks need ucode; use --emit for an isolated native fixture');
} else {
    if (native.error) throw native.error;
    process.stdout.write(native.stdout || '');
    process.stderr.write(native.stderr || '');
    assert.equal(native.status, 0, 'Native storage persistence fixture failed');

    // Check the real ucode fs API as well as the injected failure cases above.
    // Every accessible path is confined to a disposable local directory.
    const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'crow-override-test-'));
    try {
        fs.writeFileSync(path.join(sandbox, 'crow.conf'), '{}');
        fs.writeFileSync(path.join(sandbox, 'crow.conf.override'), '{"old":true}');
        const ioFixture = `
import * as realfs from "fs";
const sandbox = ${JSON.stringify(sandbox)};
const SCRIPT_NAME = sandbox + "/crow.uc";
let overrideWriteId = 0;
function confined(path) {
    if (index(path, sandbox + "/") !== 0) die("Fixture escaped its sandbox\\n");
    return path;
}
const fs = {
    access: path => index(path, sandbox + "/") === 0 && realfs.access(path),
    dirname: realfs.dirname,
    open: (path, mode, perm) => realfs.open(confined(path), mode, perm),
    rename: (from, to) => realfs.rename(confined(from), confined(to)),
    unlink: path => realfs.unlink(confined(path))
};
${extract(configSource, 'localFile')}
${extract(configSource, 'writeOverride')}
const data = sprintf("%.2J", { storage: { mode: "usb" }, label: "Operator café" });
if (!writeOverride(data) || !writeOverride(data)) die("Real filesystem save failed\\n");
const path = sandbox + "/crow.conf.override";
if (realfs.readfile(path) !== data || realfs.stat(path).mode !== 0o600)
    die("Real filesystem bytes or permissions differ\\n");
if (length(realfs.lsdir(sandbox)) !== 2) die("Temporary override file leaked\\n");
print("PASS: native filesystem atomic replacement, UTF-8 bytes, private permissions, and temporary-file cleanup\\n");
`;
        const io = spawnSync(process.env.UCODE || 'ucode', ['-'], {input: ioFixture, encoding: 'utf8'});
        if (io.error) throw io.error;
        process.stdout.write(io.stdout || ''); process.stderr.write(io.stderr || '');
        assert.equal(io.status, 0, 'Native filesystem writer fixture failed');
    } finally {
        fs.rmSync(sandbox, {recursive: true, force: true});
    }
}
