#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'ui', 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(root, 'ui', 'ui.css'), 'utf8');
const ui = fs.readFileSync(path.join(root, 'ui', 'ui.js'), 'utf8');
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

check('header provides a local node-name target',
    html.includes('<div id="node-name" title="Local node name"></div>'));
check('me event renders the same long name used by node info',
    ui.includes('const nodeName = String(me.long_name ?? "").trim();') &&
    ui.includes('I("node-name").textContent = nodeName;'));
check('node name is assigned safely without innerHTML',
    !ui.includes('I("node-name").innerHTML'));
check('long node names truncate within the header',
    /#node-name[\s\S]*?text-overflow:\s*ellipsis;[\s\S]*?white-space:\s*nowrap;/.test(css));

if (failures) {
    console.error('\n' + failures + ' header node-name test(s) failed');
    process.exit(1);
}
console.log('\nHeader node-name checks passed');
