#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const TTL = 1800;
const MAX = 64;
const seen = new Map();
const order = [];

function duplicate(backend, from, id, now) {
    if (!id) return false;
    while (order.length && now - order[0].when >= TTL) {
        const oldest = order.shift();
        if (seen.get(oldest.key) === oldest.when) seen.delete(oldest.key);
    }
    const key = `${backend ?? ''}:${String(from ?? '').trim().toUpperCase()}:${id}`;
    if (seen.has(key) && now - seen.get(key) < TTL) return true;
    seen.set(key, now);
    order.push({ key, when: now });
    while (order.length > MAX) {
        const oldest = order.shift();
        if (seen.get(oldest.key) === oldest.when) seen.delete(oldest.key);
    }
    return false;
}

function crowMessageId(from, id) {
    const digest = crypto.createHash('sha1').update(`aprs:${String(from).trim().toUpperCase()}:${id}`).digest();
    return digest.readUInt32BE(0);
}

let failures = 0;
function check(name, got, want) {
    if (got === want) {
        console.log(`ok   - ${name}`);
    } else {
        failures++;
        console.log(`FAIL - ${name}\n   got:  ${got}\n   want: ${want}`);
    }
}

check('first delivery is accepted', duplicate('xastir', 'kj6dzb-4', '101', 1000), false);
check('same backend sender and id is dropped', duplicate('xastir', 'KJ6DZB-4', '101', 1002), true);
check('different message id is accepted', duplicate('xastir', 'KJ6DZB-4', '102', 1002), false);
check('different sender is accepted', duplicate('xastir', 'KJ6ABC-1', '101', 1002), false);
check('different backend is accepted', duplicate('aprsis', 'KJ6DZB-4', '101', 1002), false);
check('message without id is not deduplicated', duplicate('xastir', 'KJ6DZB-4', null, 1002), false);
check('expired message id is accepted', duplicate('xastir', 'KJ6DZB-4', '101', 2800), false);
check('same APRS packet gets the same Crow id on every gateway',
    crowMessageId('kj6dzb-4', '101'), crowMessageId('KJ6DZB-4', '101'));
check('different APRS packet gets a different Crow id',
    crowMessageId('KJ6DZB-4', '101') === crowMessageId('KJ6DZB-4', '102'), false);

for (let i = 0; i < MAX + 8; i++) duplicate('xastir', 'N0CALL', String(i), 3000 + i);
check('cache remains bounded', order.length, MAX);

const source = fs.readFileSync(path.join(__dirname, '..', 'aprs.uc'), 'utf8');
const receiveStart = source.indexOf('function receiveLine(line, backendName)');
const receiveEnd = source.indexOf('// --- Outbound text parsing ---', receiveStart);
const receiveSource = source.slice(receiveStart, receiveEnd);
check('production code ACKs before duplicate check',
    receiveSource.indexOf('sendAck(') < receiveSource.indexOf('inboundDuplicate('), true);
check('production cache is capped for constrained nodes',
    source.includes('const INBOUND_DEDUPE_MAX = 64;'), true);
check('production exposes dropped retry count',
    source.includes('duplicates_dropped: inst.duplicates_dropped'), true);
check('production assigns deterministic cross-gateway APRS id',
    source.includes('extra.id = stableId'), true);

const textSource = fs.readFileSync(path.join(__dirname, '..', 'textmessage.uc'), 'utf8');
check('retained APRS retry guard handles legacy text-store ids',
    textSource.includes('function isAprsRetryCopy(chanmessages, msg, text, textfrom)'), true);

const total = 15;
console.log(`\n${total - failures} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
