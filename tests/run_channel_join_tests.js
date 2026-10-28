#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const root = process.env.CROW_SOURCE_ROOT || path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const runnable = source => source.replace(/^import .*;\s*$/gm, '').replace(/^export function /gm, 'function ');

const channel = {
  getAllLocalChannels: () => [{namekey:'AREDN og==',telemetry:true,backend:''}],
  getLocalChannelByNameKey: n => n === 'AREDN og==' ? {namekey:n} : null
};
const textmessage = {state: () => ({max:150,badge:true,images:true,winlink:false})};
let recorded = [];
const context = vm.createContext({
  channel, textmessage, event:{queue:e=>recorded.push(e)}, aprs:{enabled:false},
  crypto:{sha256hash:s=>[...crypto.createHash('sha256').update(s).digest()]},
  struct:{pack:(fmt,...bytes)=>Buffer.from(bytes.slice(0,parseInt(fmt))).toString('latin1')},
  b64enc:s=>Buffer.from(s,'latin1').toString('base64'),
  length:x=>x?.length || 0, ord:(s,n=0)=>s?.charCodeAt(n),
  slice:(a,...args)=>a.slice(...args), map:(a,fn)=>a.map(fn), push:(a,x)=>a.push(x),
  split:(s,sep)=>s.split(sep), trim:s=>s.trim(), lc:s=>s.toLowerCase(), uc:s=>s.toUpperCase(),
  match:(s,re)=>s.match(re), replace:(s,re,v)=>s.replace(re,v), chr:String.fromCharCode,
  DEBUG0:()=>{}
});
vm.runInContext(`this.groups = (() => {${runnable(read('groups.uc'))}\nreturn {parseJoinArgs,createGroupChannel};})();`,context);
vm.runInContext(runnable(read('commands.uc')),context);
function post(args) {
  recorded=[];context.post(args,'fixture','AREDN og==');
  return recorded.filter(e=>e.cmd==='newchannels');
}
let events=post(['join','%Ops']);
assert.equal(events.length,1,'short join must dispatch, not return Unknown command');
assert.equal(events[0].channels[1].namekey,'%Ops og==');
assert.equal(events[0].channels[0].namekey,'AREDN og==');
assert.equal(events[0].channels[0].max,150);
events=post(['join','#Ops']);
assert.equal(events[0].channels[1].namekey,`#Ops ${crypto.createHash('sha256').update('#Ops').digest().subarray(0,16).toString('base64')}`);
for (const args of [['join'],['join','AREDN']]) {
  assert.equal(post(args).length,0);
  assert.equal(recorded[0].reply[0],'Usage:');
}
assert.equal(post(['channels','join','%Ops'])[0].channels[1].namekey,'%Ops og==');
assert.equal(post(['channels','join','AREDN','og==']).length,0);
console.log('PASS: actual short/long join dispatch, shared key, invalid syntax, retained settings, and duplicate prevention');

function nativeFixture(dir) {
  fs.mkdirSync(dir,{recursive:true});
  for (const name of ['commands.uc','groups.uc']) fs.copyFileSync(path.join(root,name),path.join(dir,name));
  fs.cpSync(path.join(root,'crypto'),path.join(dir,'crypto'),{recursive:true});
  fs.copyFileSync(path.join(__dirname,'test_channel_join.uc'),path.join(dir,'test_channel_join.uc'));
  for (const name of ['router','message','node','aprs','meshcore_backend','meshtastic_backend','gatekeeper','channel_export']) {
    fs.writeFileSync(path.join(dir,name+'.uc'),'export const enabled = false;\n');
  }
  fs.writeFileSync(path.join(dir,'channel.uc'),`export function getAllLocalChannels() { return [{namekey:"AREDN og==",telemetry:true,backend:""}]; };
export function getLocalChannelByNameKey(n) { return n === "AREDN og==" ? {namekey:n} : null; };
`);
  fs.writeFileSync(path.join(dir,'textmessage.uc'),'export function state(n) { return {max:150,badge:true,images:true,winlink:false}; };\n');
}
if (process.argv[2] === '--native-fixture') {
  assert.ok(process.argv[3],'fixture output directory is required');
  nativeFixture(path.resolve(process.argv[3]));
  console.log('Native inert fixture prepared. Run: ucode -L <fixture-directory> <fixture-directory>/test_channel_join.uc');
} else {
  const probe=spawnSync('ucode',['-h']);
  if (probe.error?.code === 'ENOENT') {
    console.log('SKIP: native join fixture needs ucode');
  } else {
    const dir=fs.mkdtempSync(path.join(os.tmpdir(),'crow-join-tests-'));
    try {
      nativeFixture(dir);
      const run=spawnSync('ucode',['-L',dir,path.join(dir,'test_channel_join.uc')],{encoding:'utf8'});
      process.stdout.write(run.stdout || '');process.stderr.write(run.stderr || '');
      assert.equal(run.status,0,'native join fixture failed');
    } finally {fs.rmSync(dir,{recursive:true,force:true});}
  }
}
