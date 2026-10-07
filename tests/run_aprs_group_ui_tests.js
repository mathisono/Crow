#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '..', 'ui', 'ui.js'), 'utf8');
const match = source.match(/function channelDisplayName\(namekey\)\n\{[\s\S]*?\n\}/);

if (!match) {
    console.error('FAIL - channelDisplayName implementation not found');
    process.exit(1);
}

const channelDisplayName = Function(`"use strict"; return (${match[0]});`)();
const cases = [
    ['APRS group hides internal percent marker', '%APRSTest og==', 'APRSTest'],
    ['ordinary APRS channel remains unchanged', 'APRS-IS og==', 'APRS-IS'],
    ['hash-prefixed bridge channel remains unchanged', '#APRSBridge og==', '#APRSBridge'],
    ['empty namekey remains safe', null, ''],
];

let failures = 0;
for (const [name, input, expected] of cases) {
    const actual = channelDisplayName(input);
    if (actual === expected) {
        console.log(`ok   - ${name}`);
    }
    else {
        failures++;
        console.error(`FAIL - ${name}\n   got:  ${actual}\n   want: ${expected}`);
    }
}

if (!source.includes('esc(channelDisplayName(namekey))')) {
    failures++;
    console.error('FAIL - channel row does not use channelDisplayName');
}
else {
    console.log('ok   - channel row uses the display-only name');
}

console.log(`\n${cases.length + 1 - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
