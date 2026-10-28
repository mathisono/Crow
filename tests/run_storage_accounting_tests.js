#!/usr/bin/env node
'use strict';
// Execute the actual AREDN storage functions in ucode, with inert I/O.
// --emit prints the fixture for a target device that has ucode installed.
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const source = fs.readFileSync(path.join(__dirname, '../platforms/aredn/platform.uc'), 'utf8');
function body(name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`Missing function ${name}`);
  const end = source.indexOf('\n}', start);
  if (end < 0) throw new Error(`Missing end of ${name}`);
  return source.slice(start, end + 2);
}
const fixture = `
const CROW_USB_MOUNT="/mnt/crow";
const CROW_USB_LABEL="CROWDATA";
const DEFAULT_IMAGE_QUOTA=67108864;
const DEFAULT_MIN_FREE=16777216;
let storageMode,storageMountpoint,storageLabel,storageDevice,storageImageQuota,storageMinFree,storageState,storageConfig;
let dfText="Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/sda1 200000 10000 190000 5% /mnt/crow\\n";
const fs={
  popen:function(){return {read:function(){return dfText;},close:function(){}};},
  lsdir:function(){return ["sda"];}
};
function safeShellArg(p){return p;}
function setInternalStorage(){storageState="internal";}
function hasUsbPort(){return true;}
function activateMountedUsb(){storageState="usb";return true;}
function currentMountDevice(){return "/dev/sda1";}
function partitionForBlock(){return "/dev/sda1";}
function blockInfo(){return {LABEL:"CROWDATA",TYPE:"ext4",UUID:"fixture"};}
function readTrim(p){
  if (substr(p,-10)==="/removable") return "1";
  if (substr(p,-5)==="/size") return "15826944";
  return "Fixture USB";
}
${body('freeBytes')}
${body('storageScan')}
${body('setupStorage')}
let passed=0;
function check(name,got,want){
  if(got!==want)die(sprintf("FAIL %s: got %J expected %J\\n",name,got,want));
  passed++;printf("ok - %s\\n",name);
}
setupStorage({storage:{mode:"usb",image_quota_mb:"64",min_free_mb:"16"}});
check("disk capacity uses numeric sectors",storageScan()[0].size_bytes,15826944*512);
check("available bytes enforce the actual free-space guard",freeBytes("/mnt/crow"),190000*1024);
check("string image quota is numeric",storageImageQuota,64*1024*1024);
check("string free-space threshold is numeric",storageMinFree,16*1024*1024);
dfText="invalid output";
check("malformed df output is unknown",freeBytes("/mnt/crow"),null);
printf("%d native storage accounting checks passed\\n",passed);
`;
if (process.argv.includes('--emit')) { process.stdout.write(fixture); process.exit(0); }
const result = spawnSync(process.env.UCODE || 'ucode', ['-'], {input:fixture, encoding:'utf8'});
if (result.error?.code === 'ENOENT') {
  console.log('SKIP: native storage accounting checks require ucode; use --emit for a target fixture');
  process.exit(0);
}
if (result.error) throw result.error;
process.stdout.write(result.stdout || ''); process.stderr.write(result.stderr || '');
process.exit(result.status ?? 1);
