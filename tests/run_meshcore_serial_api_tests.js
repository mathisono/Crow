// Node-runnable contract tests for the direct USB Companion backend.
// They cover the wire representation independently of a physical RAK board;
// hardware verification is documented in MESHCORE_USB_SERIAL_COMPANION_BACKEND.md.

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const SOURCE = fs.readFileSync('meshcore_serial_api.uc', 'utf8');
const FROM_RADIO = 0x3e;
const TO_RADIO = 0x3c;
const CMD_APP_START = 0x01;
const CMD_SEND_CHANNEL_TEXT = 0x03;
const CMD_SYNC_NEXT = 0x0a;
const RESP_DIRECT = 0x07;
const RESP_GROUP = 0x08;
const RESP_DIRECT_V3 = 0x10;
const RESP_GROUP_V3 = 0x11;
const PUSH_WAITING = 0x83;
const MAX_PAYLOAD = 256;

let count = 0;
function ok(name, condition) {
  count++;
  assert.ok(condition, name);
  console.log(`ok   - ${name}`);
}
function eq(name, actual, expected) {
  count++;
  assert.deepStrictEqual(actual, expected, name);
  console.log(`ok   - ${name}`);
}

function command(code, payload = Buffer.alloc(0)) {
  const p = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const body = Buffer.concat([Buffer.from([code]), p]);
  return Buffer.concat([Buffer.from([TO_RADIO, body.length & 0xff, body.length >> 8]), body]);
}
function radioFrame(code, payload = Buffer.alloc(0)) {
  const p = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const body = Buffer.concat([Buffer.from([code]), p]);
  return Buffer.concat([Buffer.from([FROM_RADIO, body.length & 0xff, body.length >> 8]), body]);
}
function u32le(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n >>> 0);
  return b;
}
function groupPayload(from, slot, text) {
  // MeshCore RESP_CODE_CHANNEL_MSG_RECV: slot, path length, text type,
  // sender timestamp, plain text. `from` is intentionally unused: channel
  // frames do not contain a sender node-id field.
  return Buffer.concat([Buffer.from([slot, 0xff, 0x00]), u32le(0x11223344), Buffer.from(text)]);
}
function directPayload(from, to, text) {
  // MeshCore RESP_CODE_CONTACT_MSG_RECV: six-byte public-key prefix, path
  // length, text type, sender timestamp, plain text. It has no to-id field.
  const prefix = Buffer.from([from & 0xff, (from >>> 8) & 0xff, (from >>> 16) & 0xff, (from >>> 24) & 0xff, 0xaa, 0xbb]);
  return Buffer.concat([prefix, Buffer.from([0xff, 0x00]), u32le(0x55667788), Buffer.from(text)]);
}
function groupSend(slot, timestamp, text) {
  return command(CMD_SEND_CHANNEL_TEXT,
    Buffer.concat([Buffer.from([0x00, slot]), u32le(timestamp), Buffer.from(text)]));
}

function decodeQueuedText(cmd, payload) {
  const isDirect = cmd === RESP_DIRECT || cmd === RESP_DIRECT_V3;
  const isGroup = cmd === RESP_GROUP || cmd === RESP_GROUP_V3;
  if (!isDirect && !isGroup) return null;
  const off = (cmd === RESP_DIRECT_V3 || cmd === RESP_GROUP_V3) ? 3 : 0;
  if (isDirect) {
    if (payload.length < off + 12 || payload[off + 7] !== 0) return null;
    return {
      direct: true,
      prefix: payload.subarray(off, off + 6),
      timestamp: payload.readUInt32LE(off + 8),
      text: payload.subarray(off + 12).toString().replace(/\0+$/, '')
    };
  }
  if (payload.length < off + 7 || payload[off] > 7 || payload[off + 2] !== 0) return null;
  return {
    direct: false,
    slot: payload[off],
    timestamp: payload.readUInt32LE(off + 3),
    text: payload.subarray(off + 7).toString().replace(/\0+$/, '')
  };
}

class Accumulator {
  constructor() {
    this.buf = Buffer.alloc(0);
    this.skip = 0;
    this.syncCommands = [];
    this.droppedOversize = 0;
    this.resyncs = 0;
  }
  inject(chunk) {
    chunk = Buffer.from(chunk);
    if (this.skip) {
      const n = Math.min(this.skip, chunk.length);
      this.skip -= n;
      chunk = chunk.subarray(n);
      if (this.skip) return [];
    }
    this.buf = Buffer.concat([this.buf, chunk]);
    const out = [];
    for (;;) {
      if (!this.buf.length) return out;
      if (this.buf[0] !== FROM_RADIO) {
        const at = this.buf.indexOf(FROM_RADIO, 1);
        if (at < 0) return out;
        this.resyncs++;
        this.buf = this.buf.subarray(at);
        continue;
      }
      if (this.buf.length < 3) return out;
      const plen = this.buf.readUInt16LE(1);
      if (plen < 1) {
        this.buf = this.buf.subarray(3);
        continue;
      }
      if (plen > MAX_PAYLOAD) {
        this.droppedOversize++;
        const total = 3 + plen;
        if (this.buf.length >= total) this.buf = this.buf.subarray(total);
        else {
          this.skip = total - this.buf.length;
          this.buf = Buffer.alloc(0);
        }
        continue;
      }
      if (this.buf.length < 3 + plen) return out;
      const payload = this.buf.subarray(3, 3 + plen);
      this.buf = this.buf.subarray(3 + plen);
      if (payload[0] === PUSH_WAITING) {
        this.syncCommands.push(command(CMD_SYNC_NEXT));
      } else {
        out.push({ cmd: payload[0], payload: payload.subarray(1) });
      }
    }
  }
}

// Source-level safety checks: direct USB code must use actual ucode fs
// handles, fixed serial setup components and strict device validation—not a
// TCP bridge. A bundled ioctl helper provides raw termios setup on stripped
// AREDN images that omit stty.
ok('uses one bidirectional direct USB handle', SOURCE.includes('const serial = fs.open(serialDevice, "r+")') && SOURCE.includes('serialRx = serial') && SOURCE.includes('serialTx = serial'));
ok('rejects missing or non-device USB paths before opening', SOURCE.includes('deviceStat.type !== "char"'));
ok('avoids handing a raw TTY to socket.poll()', SOURCE.includes('return null;') && SOURCE.includes('meshcore_serial_api.poll'));
ok('drains serial through a nonblocking timer', SOURCE.includes('function pumpSerial(reason)') && SOURCE.includes('timers.setInterval("meshcore_serial_api.poll", SERIAL_POLL_INTERVAL)'));
ok('defaults only the standard public channel as the safe TX target', SOURCE.includes('cfg.channel_namekey ?? channel.meshcorePublicChannelNamekey()') && SOURCE.includes('verifiedLocalChannelForSlot(outboundChannelIndex, configuredChannelNamekey)'));
ok('uses fixed serial configuration after strict path validation', SOURCE.includes('fs.popen(command, "r")') && SOURCE.includes('if (!validDevicePath(serialDevice))'));
ok('validates only ttyACM/ttyUSB paths', SOURCE.includes('/^\\/dev\\/ttyACM[0-9]+$/') && SOURCE.includes('/^\\/dev\\/ttyUSB[0-9]+$/'));
ok('does not use a serial TCP bridge', !SOURCE.includes('ser2net') && !SOURCE.includes('TCP:') && !SOURCE.includes('TCP-LISTEN:'));
ok('uses the bundled rawtty fallback when stty is absent', SOURCE.includes('RAWTTY_HELPER') && SOURCE.includes('bundled rawtty setup'));
ok('bundled rawtty source is present', fs.existsSync('tools/crow-rawtty/main.go'));
ok('bounds decoded serial frames to pending budget', SOURCE.includes('early_drop_queue_full') && SOURCE.includes('deferredFrames'));
ok('handles the real v3 queued-message prefix', SOURCE.includes('function incomingPrefixBytes(cmd)'));
ok('rejects direct outbound messages', SOURCE.includes('channel.isDirect(msg.namekey)'));
ok('uses real MeshCore group send command', SOURCE.includes('CMD_SEND_CHANNEL_TXT_MSG = 0x03'));
ok('parses self-info from its printable trailing name', SOURCE.includes('function _test_parse_self_info(payload)') && SOURCE.includes('while (start > 0)'));
ok('does not map a configured TX slot before discovery', !SOURCE.includes('channel.setMeshcoreSlotChannel(outboundChannelIndex, configured)'));
ok('requires exact tuple proof before serial send', SOURCE.includes('verifiedLocalChannelForSlot(outboundChannelIndex, configuredChannelNamekey)'));
ok('normalizes Companion Public to Crow public namekey', SOURCE.includes('name === "Public"') && SOURCE.includes('channel.meshcorePublicChannelNamekey()'));
ok('waits for self-info before queue sync', SOURCE.includes('Wait for self-info or a queue push') && SOURCE.includes('companionReady && syncingMessages') && SOURCE.includes('if (cmd === RESP_SELF_INFO)'));
ok('retries and reconnects after a lost serial handshake', SOURCE.includes('SERIAL_HANDSHAKE_ATTEMPTS') && SOURCE.includes('handshakeAttempts >= SERIAL_HANDSHAKE_ATTEMPTS') && SOURCE.includes('closeSerial("handshake timeout")'));
ok('exposes serial handshake readiness', SOURCE.includes('handshake_ready: companionReady') && SOURCE.includes('handshake_attempts: handshakeAttempts'));
ok('drops unverified serial group receive', SOURCE.includes('group_receive_unverified') && SOURCE.includes('until radio/Crow channel namekey matches'));
ok('clears serial slot authority on reconnect', SOURCE.includes('channel.clearMeshcoreSlotChannels()') && SOURCE.includes('discoveredChannels = {}'));
ok('keeps Companion channel datagrams opt-in', SOURCE.includes('channel_data_text_types') && SOURCE.includes('channel_data_unrouted'));
ok('bounds Companion channel datagrams', SOURCE.includes('MAX_CHANNEL_DATA_LENGTH') && SOURCE.includes('validChannelDataPayload') && SOURCE.includes('dataLen <= MAX_CHANNEL_DATA_LENGTH'));
ok('reports modern direct identity as unverified', SOURCE.includes('direct_identity_verified: false') && SOURCE.includes('direct_identity_unverified++'));
ok('supports strict modern direct identity mode', SOURCE.includes('direct_identity_mode === "verified"') && SOURCE.includes('direct_identity_dropped'));

// ucode module exports are declarations terminated with `};`.  Node's wire
// contract tests do not parse ucode, so keep this target-runtime requirement
// explicit: omitting the semicolon prevents the module from compiling on
// AREDN's ucode interpreter.
for (const name of [
  'sendCommand', 'setup', 'shutdown', 'handle', 'recv', 'send', 'tick',
  'process', 'pending', 'takeResponse', 'status', '_test_reset',
  '_test_inject', '_test_decode', '_test_build_frame', '_test_build_command',
  '_test_build_group_send', '_test_app_start_payload', '_test_decode_channel_info',
  '_test_stats', '_test_set_channel_data_text_types',
  '_test_set_strict_direct_identity'
]) {
  const expression = new RegExp(`export function ${name}\\([^]*?\\n};`);
  ok(`ucode export ${name} has a declaration terminator`, expression.test(SOURCE));
}

{
  const f = command(CMD_APP_START, Buffer.from([0x03, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, ...Buffer.from('Crow')]));
  eq('handshake marker is <', f[0], TO_RADIO);
  eq('handshake uses uint16le payload length', f.readUInt16LE(1), 12);
  eq('handshake command is CMD_APP_START', f[3], CMD_APP_START);
}
{
  const f = groupSend(3, 0x11223344, 'Crow TX');
  eq('group text marker is <', f[0], TO_RADIO);
  eq('group text command is 0x03', f[3], CMD_SEND_CHANNEL_TEXT);
  eq('group text type is plain', f[4], 0x00);
  eq('group text includes configured channel slot', f[5], 3);
  eq('group text timestamp is little endian', f.readUInt32LE(6), 0x11223344);
  eq('group text preserves message body', f.subarray(10).toString(), 'Crow TX');
}
{
  const a = new Accumulator();
  const f = radioFrame(RESP_DIRECT, directPayload(1, 2, 'fragment'));
  eq('fragmented direct first piece held', a.inject(f.subarray(0, 2)).length, 0);
  eq('fragmented direct second piece held', a.inject(f.subarray(2, 7)).length, 0);
  eq('fragmented direct decodes when complete', a.inject(f.subarray(7)).length, 1);
}
{
  const direct = decodeQueuedText(RESP_DIRECT, directPayload(0x11223344, 0, 'direct rx'));
  eq('old direct frame decodes six-byte source prefix', direct.prefix.length, 6);
  eq('old direct frame decodes timestamp', direct.timestamp, 0x55667788);
  eq('old direct frame decodes text after header', direct.text, 'direct rx');
}
{
  const group = decodeQueuedText(RESP_GROUP, groupPayload(0, 2, 'group rx'));
  eq('old group frame decodes actual slot position', group.slot, 2);
  eq('old group frame decodes timestamp', group.timestamp, 0x11223344);
  eq('old group frame decodes text after metadata', group.text, 'group rx');
}
{
  const payload = Buffer.concat([Buffer.from([0xf8, 0x00, 0x00]), groupPayload(0, 5, 'v3 group')]);
  const group = decodeQueuedText(RESP_GROUP_V3, payload);
  eq('v3 group skips SNR/reserved prefix', group.slot, 5);
  eq('v3 group text survives prefix skip', group.text, 'v3 group');
}
{
  const malformed = Buffer.from([1, 0xff, 1, 0, 0, 0, 0, ...Buffer.from('bad type')]);
  eq('non-plain group records are rejected', decodeQueuedText(RESP_GROUP, malformed), null);
}
{
  const a = new Accumulator();
  const f = radioFrame(RESP_GROUP, groupPayload(0x12345678, 2, 'group rx'));
  const decoded = a.inject(Buffer.concat([Buffer.from([0, 1, 2]), f]));
  eq('resync recovers after serial garbage', decoded.length, 1);
  eq('resync was counted', a.resyncs, 1);
}
{
  const a = new Accumulator();
  a.inject(Buffer.from([FROM_RADIO, 0x01, 0x01])); // 257-byte claimed frame
  eq('oversize companion frame is dropped', a.droppedOversize, 1);
}
{
  const a = new Accumulator();
  a.inject(radioFrame(PUSH_WAITING));
  eq('0x83 produces CMD_SYNC_NEXT_MESSAGE', a.syncCommands[0][3], CMD_SYNC_NEXT);
}

// Mirror the serial backend's exact name/key/slot gate. A configured slot by
// itself must never authorize RF receive or send.
{
  const local = new Set(['TacNet AQ==']);
  const discovered = new Map();
  const mapped = new Map();
  const configure = (slot, namekey) => {
    discovered.set(slot, namekey);
    if (local.has(namekey)) mapped.set(slot, namekey);
    else mapped.delete(slot);
  };
  const allowed = (slot, namekey) => local.has(namekey) &&
    discovered.get(slot) === namekey && mapped.get(slot) === namekey;

  eq('serial gate: configured slot alone is blocked', allowed(5, 'TacNet AQ=='), false);
  configure(5, 'TacNet Ag==');
  eq('serial gate: wrong key is blocked', allowed(5, 'TacNet AQ=='), false);
  configure(4, 'TacNet AQ==');
  eq('serial gate: exact tuple on wrong slot is blocked', allowed(5, 'TacNet AQ=='), false);
  configure(5, 'TacNet AQ==');
  eq('serial gate: exact discovered tuple is allowed', allowed(5, 'TacNet AQ=='), true);
}

// Run canonical ucode hooks when a target interpreter is available.  This is
// intentionally optional on developer machines; Node coverage above stays
// runnable without an OpenWrt SDK.
const probe = spawnSync('sh', ['-lc', 'command -v ucode'], { encoding: 'utf8' });
if (probe.status === 0) {
  const child = spawnSync('ucode', ['-R', '-L', path.resolve('.'), 'tests/test_meshcore_serial_api.uc'], { encoding: 'utf8' });
  process.stdout.write(child.stdout || '');
  process.stderr.write(child.stderr || '');
  if (child.status !== 0) process.exit(child.status || 1);
} else {
  console.log('note - ucode not installed; canonical ucode test skipped');
}

console.log(`\n${count} serial Companion contract checks passed`);
