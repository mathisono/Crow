'use strict';

const assert = require('assert');
const fs = require('fs');

const selector = fs.readFileSync('meshcore_backend.uc', 'utf8');
const serial = fs.readFileSync('meshcore_serial_api.uc', 'utf8');

assert(selector.includes('import * as serialApi from "meshcore_serial_api";'));
assert(selector.includes('mode === "serial" || mode === "serial-api"'));
assert(selector.includes('config.meshcore_serial_api?.enabled === true'));
assert(selector.includes('activeName = "serial"'));
assert(selector.includes('active = api'));
assert(selector.includes('active = udp'));
assert(serial.includes('fs.open(serialDevice, "r")'));
assert(serial.includes('fs.open(serialDevice, "w")'));
assert(serial.includes('return serialRx;'));
assert(serial.includes('CMD_SEND_CHANNEL_TXT_MSG = 0x03'));
console.log('meshcore backend selector checks passed');
