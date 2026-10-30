#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const root = process.env.CROW_SOURCE_ROOT || path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
function extract(source, name, optional = false) {
    const found = source.match(new RegExp(`function ${name}\\([^)]*\\)\\n\\{[\\s\\S]*?^\\}`, 'm'));
    if (optional && !found) return `function ${name}() {}`;
    assert.ok(found, name);
    return found[0];
}
const config = read('config.uc');
const callback = config.match(/config\.storageChanged = function\(\) \{([\s\S]*?)\n    \};/);
const fixture = `
const CROW_INTERNAL_ROOT = '/internal', CROW_TMP_ROOT = '/tmp';
let storageRoot = '/usb', storageImageRoot, storageState = 'usb', storageReason;
let storageMountpoint = '/usb', storageConfig = null, ramMessages = false;
let writes = 0, healthy = true;
const channelmessages = { test: { max: 25, images: false, messages: [{id: 9, text: 'retained'}] } };
const channelmessagesdirty = {};
const stores = { test: { size: 50, messages: [{id: 8, text: 'store retained'}] } };
const dirty = {};
const disks = { '/internal': { 'messages.test': {images:true,messages:[]} }, '/usb': {} };
function clone(x) { return json(sprintf('%J', x)); }
function check(ok, label) { if (!ok) die('FAIL: ' + label + '\\n'); }
function mkdirp() {}
function currentMountDevice() { return '/dev/sda1'; }
function prepareStorageRoot() { return healthy ? null : 'unhealthy'; }
function migrateDataToUsb() {}
const platform = { store: function(name, data) { disks[storageRoot][name]=clone(data); writes++; } };
const node = { getInfo: function() { return {id:7,private_key:'synthetic-key'}; } };
${extract(read('textmessage.uc'), 'saveToPlatform').replace('function saveToPlatform(', 'function saveMessagesToPlatform(')}
${extract(read('textstore.uc'), 'saveToPlatform').replace('function saveToPlatform(', 'function saveTextstoreToPlatform(')}
const textmessage = { storageChanged: ${extract(read('textmessage.uc'), 'storageChanged', true).replace('function storageChanged(', 'function(').replace('saveToPlatform();', 'saveMessagesToPlatform();')} };
const textstore = { storageChanged: ${extract(read('textstore.uc'), 'storageChanged', true).replace('function storageChanged(', 'function(').replace('saveToPlatform();', 'saveTextstoreToPlatform();')} };
${['setInternalStorage','setDegradedStorage','activateMountedUsb'].map(name=>extract(read('platforms/aredn/platform.uc'),name)).join('\n')}
storageConfig = { storageChanged: function() { ${callback ? callback[1] : ''} } };

setInternalStorage();
check(sprintf('%J', disks['/internal']['messages.test'])===sprintf('%J', channelmessages.test), 'clean channel preferences/history must move to internal storage');
check(sprintf('%J', disks['/internal']['textstore.test'])===sprintf('%J', stores.test), 'clean textstore must move to internal storage');
check(disks['/internal'].node.private_key==='synthetic-key', 'node identity must move to internal storage');
check(!channelmessagesdirty.test && !dirty.test, 'checkpoint clears dirty state');
print('ok - USB to internal checkpoints clean message/preferences, textstore, and identity\\n');

// Emulate the next process loading its selected disk; old USB contents must
// not replace the current active state after returning to USB.
channelmessages.test=clone(disks['/internal']['messages.test']);
channelmessages.test.images=true;
channelmessages.test.messages[0].text='current after restart';
disks['/usb']['messages.test']={images:false,messages:[]};
check(activateMountedUsb(), 'USB activation succeeds');
check(sprintf('%J',disks['/usb']['messages.test'])===sprintf('%J',channelmessages.test), 'clean current state must move back to USB');
check(disks['/usb'].node.private_key==='synthetic-key', 'USB identity retained');
print('ok - internal restart then USB activation preserves current clean state\\n');

let before=writes;
check(activateMountedUsb(), 'repeat USB activation succeeds');
check(writes===before, 'status/no-op activation must not rewrite data');
setInternalStorage(); before=writes; setInternalStorage();
check(writes===before, 'repeat internal selection must not rewrite data');
print('ok - no-op root selection does not checkpoint repeatedly\\n');

storageConfig=null;
disks['/usb']['messages.test']={images:false,messages:[{id:77}]};
before=writes;
check(activateMountedUsb(), 'startup USB selection succeeds');
check(writes===before && disks['/usb']['messages.test'].messages[0].id===77, 'startup must load its selected store before installing callbacks');
print('ok - startup selection does not overwrite existing destination data\\n');

storageConfig={storageChanged:function(){${callback ? callback[1] : ''}}};
setDegradedStorage('fixture USB unavailable');
check(storageState==='degraded' && disks['/internal']['messages.test'].images===true, 'degraded fallback checkpoints current state');
print('ok - degraded fallback preserves current active state\\n');
print('5 storage-switch state checks passed\\n');
`;
if (process.argv.includes('--emit')) { process.stdout.write(fixture); process.exit(0); }
vm.runInNewContext(fixture, {
    json: JSON.parse, sprintf: (format, value) => JSON.stringify(value),
    print: text => process.stdout.write(text), die: text => { throw new Error(text); }
});
const result=spawnSync(process.env.UCODE || 'ucode',['-'],{input:fixture,encoding:'utf8'});
if (result.error?.code==='ENOENT') console.log('SKIP: native storage-switch checks need ucode');
else {
    if (result.error) throw result.error;
    process.stdout.write(result.stdout || ''); process.stderr.write(result.stderr || '');
    assert.equal(result.status,0,'Native storage-switch state checks failed');
}
if (callback) {
    assert.ok(config.indexOf('config.storageChanged =') > config.indexOf('textmessage.setup(config)'), 'hook must be installed after state loading');
    assert.ok(config.indexOf('config.storageChanged =') > config.indexOf('textstore.setup(config)'), 'textstore must be loaded first');
}
