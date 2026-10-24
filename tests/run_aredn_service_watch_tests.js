#!/usr/bin/env node
'use strict';

// Exercise the actual compatibility functions with both AREDN API contracts.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../platforms/aredn/platform.uc'), 'utf8');
const functions = ['startServiceWatcher', 'stopServiceWatcher', 'handleChanges'].map(name => {
    const match = source.match(new RegExp(`function ${name}\\(\\)\\n\\{[\\s\\S]*?^\\}`, 'm'));
    assert.ok(match, `Missing ${name}`);
    return match[0];
}).join('\n');

function fixture(modern) {
    const calls = { starts: 0, closes: 0, unwatch: 0, refresh: 0, read: 0 };
    const resource = { ioctl: () => 5, read: n => { calls.read += n; }, close: () => calls.closes++ };
    const pipe = { fileno: () => 7 };
    const owner = { handle: () => resource, changes: () => 'changed', close: () => calls.closes++ };
    const context = vm.createContext({
        pwatcher: null, watcher: null, type: value => typeof value,
        services: {
            watch: topic => { assert.equal(topic, 'publish'); calls.starts++; return modern ? owner : pipe; },
            unwatch: value => { assert.equal(value, pipe); calls.unwatch++; }
        },
        fs: { IOC_DIR_READ: 1, fdopen: fd => { assert.equal(modern, false); assert.equal(fd, 7); return resource; } },
        refreshTargets: () => calls.refresh++
    });
    vm.runInContext(functions, context);
    return { context, calls, resource, owner };
}

const modern = fixture(true);
modern.context.startServiceWatcher();
assert.equal(modern.context.watcher, modern.resource);
modern.context.handleChanges();
assert.equal(modern.calls.refresh, 1);
assert.equal(modern.calls.read, 0, 'New API owns reads');
modern.owner.changes = () => '';
modern.context.handleChanges();
assert.equal(modern.calls.refresh, 1, 'EAGAIN is not EOF');
modern.owner.changes = () => null;
modern.context.handleChanges();
assert.equal(modern.calls.starts, 2, 'EOF recreates watcher');
assert.equal(modern.calls.closes, 1);
modern.context.stopServiceWatcher();
modern.context.stopServiceWatcher();
assert.equal(modern.calls.closes, 2, 'Owner closes once per watcher');
assert.equal(modern.calls.unwatch, 0, 'Removed legacy API is never called');
assert.equal(modern.context.watcher, null);
assert.equal(modern.context.pwatcher, null);

const legacy = fixture(false);
legacy.context.startServiceWatcher();
assert.equal(legacy.context.watcher, legacy.resource);
legacy.context.handleChanges();
assert.equal(legacy.calls.read, 5);
assert.equal(legacy.calls.refresh, 1);
legacy.resource.ioctl = () => null;
legacy.context.handleChanges();
assert.equal(legacy.calls.starts, 2);
assert.equal(legacy.calls.unwatch, 1);
assert.equal(legacy.calls.closes, 1);
legacy.context.stopServiceWatcher();
assert.equal(legacy.calls.unwatch, 2);
assert.equal(legacy.calls.closes, 2);
assert.equal(legacy.context.watcher, null);

console.log('PASS: modern/legacy watch, changes, EAGAIN, EOF recovery, and cleanup contracts');
