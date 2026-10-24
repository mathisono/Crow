#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { spawnSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const moduleSource = fs.readFileSync(path.join(root, 'channel_export.uc'), 'utf8');
const commandsSource = fs.readFileSync(path.join(root, 'commands.uc'), 'utf8');
const eventSource = fs.readFileSync(path.join(root, 'event.uc'), 'utf8');
const uiSource = fs.readFileSync(path.join(root, 'ui', 'ui.js'), 'utf8');

let passed = 0;
let failed = 0;

function check(name, actual, expected = true) {
  if (actual === expected) {
    console.log(`ok   - ${name}`);
    passed++;
  } else {
    console.error(`FAIL - ${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    failed++;
  }
}

function sprintf(format, ...values) {
  let index = 0;
  return format.replace(/%0?(\d*)d/g, (_, width) => {
    const value = String(values[index++]);
    return width ? value.padStart(Number(width), '0') : value;
  });
}

const fixedNow = Date.UTC(2026, 0, 2, 3, 4, 5) / 1000;
const exportSandbox = {
  nodedb: {
    getNode(id) {
      if (id === 7) return { nodeinfo: { long_name: 'Remote Seven', short_name: 'R7' } };
      if (id === 8) return { nodeinfo: { short_name: 'R8' } };
      return null;
    },
  },
  length: value => value.length,
  push: (value, item) => value.push(item),
  replace: (value, pattern, replacement) => String(value).replace(pattern, replacement),
  split: (value, separator) => String(value).split(separator),
  join: (separator, value) => value.join(separator),
  localtime: epoch => {
    const date = new Date(epoch * 1000);
    return {
      year: date.getUTCFullYear(),
      mon: date.getUTCMonth() + 1,
      mday: date.getUTCDate(),
      hour: date.getUTCHours(),
      min: date.getUTCMinutes(),
      sec: date.getUTCSeconds(),
    };
  },
  sprintf,
  time: () => fixedNow,
};
vm.createContext(exportSandbox);
const runnableModule = moduleSource
  .replace(/^import .*;\s*$/gm, '')
  .replace(/^export function /gm, 'function ');
vm.runInContext(`${runnableModule}\nthis.channelExport = { build };`, exportSandbox);

const messages = [
  { when: Date.UTC(2026, 0, 2, 1, 2, 3) / 1000, from: 1, textfrom: 'Alice, "N0CALL"', text: 'hello, "world"' },
  { when: 0, from: 7, text: 'epoch zero' },
  { from: 8, text: 'two\nlines' },
  { from: 9, text: null },
];
const csv = exportSandbox.channelExport.build('#Tac/Net secret', messages, 'csv', fixedNow);
check('CSV filename strips channel marker and unsafe characters', csv.filename, 'Tac-Net-20260102-030405.csv');
check('CSV has the documented header', csv.data.startsWith('timestamp,from,message\r\n'));
check('CSV doubles quotes and quotes every data field', csv.data.includes('"Alice, ""N0CALL""","hello, ""world"""'));
check('CSV formats epoch zero instead of dropping it', csv.data.includes('"1970-01-01 00:00:00","Remote Seven","epoch zero"'));
check('CSV resolves a short node name', csv.data.includes('"","R8","two\nlines"'));
check('CSV falls back to numeric sender ID', csv.data.includes('"","9",""'));

const textExport = exportSandbox.channelExport.build('#Tac/Net secret', messages, 'text', fixedNow);
check('text filename uses txt extension', textExport.filename, 'Tac-Net-20260102-030405.txt');
check('text export names the channel without exposing its key', textExport.data.startsWith('Channel: #Tac/Net\nExported: 2026-01-02 03:04:05\n'));
check('text export resolves sender names', textExport.data.includes('[1970-01-01 00:00:00] Remote Seven: epoch zero'));

check('slash command accepts the selected channel', commandsSource.includes('export function post(cmd, id, namekey)'));
check('slash command queues a download event', commandsSource.includes('event.queue({ cmd: "/export", filename: result.filename, data: result.data, socket: id })'));
check('invalid export formats return usage', commandsSource.includes('format !== "text" && format !== "csv"'));
check('event path passes channel selection into commands', eventSource.includes('commands.post(msg.command, msg.socket, msg.namekey)'));
check('export response is scoped to requesting socket', eventSource.includes('send({ event: msg.cmd, filename: msg.filename, data: msg.data }, msg.socket)'));

const uiStart = uiSource.indexOf('function downloadExport(msg)');
const uiEnd = uiSource.indexOf('\nfunction ', uiStart + 1);
check('browser download handler exists', uiStart >= 0 && uiEnd > uiStart);

let clicked = 0;
let appended = 0;
let removed = 0;
let revoked = null;
let reply = null;
let createdBlob = null;
let createdLink = null;
const uiSandbox = {
  Blob: class Blob {
    constructor(parts, options) {
      this.parts = parts;
      this.type = options.type;
      createdBlob = this;
    }
  },
  URL: {
    createObjectURL: () => 'blob:crow-export',
    revokeObjectURL: value => { revoked = value; },
  },
  document: {
    createElement: () => {
      createdLink = { href: '', download: '', click: () => { clicked++; } };
      return createdLink;
    },
    body: {
      appendChild: () => { appended++; },
      removeChild: () => { removed++; },
    },
  },
  setTimeout: callback => callback(),
  commandReply: value => { reply = value; },
};
vm.createContext(uiSandbox);
vm.runInContext(`${uiSource.slice(uiStart, uiEnd)}\nthis.downloadExportForTest = downloadExport;`, uiSandbox);
uiSandbox.downloadExportForTest({ filename: 'TacNet-20260102-030405.csv', data: 'timestamp,from,message' });
check('browser creates CSV blob with UTF-8 MIME type', createdBlob.type, 'text/csv;charset=utf-8');
check('browser preserves export bytes', createdBlob.parts[0], 'timestamp,from,message');
check('browser assigns the server filename', createdLink.download, 'TacNet-20260102-030405.csv');
check('browser triggers exactly one download click', clicked, 1);
check('browser attaches and removes the temporary link', appended === 1 && removed === 1);
check('browser revokes the temporary object URL', revoked, 'blob:crow-export');
check('browser confirms the exported filename', reply.reply[0], 'Exported TacNet-20260102-030405.csv');

const ucode = spawnSync('sh', ['-lc', 'command -v ucode'], { encoding: 'utf8' });
if (ucode.status === 0 && ucode.stdout.trim()) {
  const canonical = spawnSync('ucode', ['-R', '-L', '.:./tests', 'tests/test_channel_export.uc'], {
    cwd: root,
    encoding: 'utf8',
  });
  process.stdout.write(canonical.stdout);
  process.stderr.write(canonical.stderr);
  check('canonical ucode export suite', canonical.status, 0);
} else {
  console.log('note - ucode not installed; canonical ucode export test skipped');
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
