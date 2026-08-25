'use strict';

// Regression smoke gate for backend additions: the serial module must expose
// the same lifecycle surface expected by the router, without changing the
// existing gatekeeper module or TCP backend.
const assert = require('assert');
const fs = require('fs');

const serial = fs.readFileSync('meshcore_serial_api.uc', 'utf8');
const tcp = fs.readFileSync('meshcore_tcp_api.uc', 'utf8');
const router = fs.readFileSync('router.uc', 'utf8');

for (const name of ['setup', 'shutdown', 'handle', 'recv', 'send', 'tick', 'pending', 'status']) {
  assert(serial.includes(`export function ${name}`), `serial lifecycle: ${name}`);
}
assert(tcp.includes('CMD_APP_START'));
assert(router.includes('msg.backend === "serial_api"'));
assert(router.includes('gatekeeper'));
console.log('router/gatekeeper backend matrix checks passed');
