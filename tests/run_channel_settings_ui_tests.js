#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
let chromium;
try { ({chromium}=require(process.env.CROW_PLAYWRIGHT_MODULE || 'playwright')); }
catch (e) {
  if (process.env.CROW_PLAYWRIGHT_MODULE || e.code !== 'MODULE_NOT_FOUND') throw e;
  console.log('SKIP: channel settings UI tests need Playwright');process.exit(0);
}
const root=process.env.CROW_SOURCE_ROOT || path.resolve(__dirname,'..');
const source=fs.readFileSync(path.join(root,'ui/ui.js'),'utf8').replace('document.addEventListener("DOMContentLoaded", startup);','');
const html=fs.readFileSync(path.join(root,'ui/index.html'),'utf8').replace(/<script[\s\S]*?<\/script>/g,'');
const css=fs.readFileSync(path.join(root,'ui/ui.css'),'utf8');
const state=()=>({count:0,cursor:null,max:150,badge:true,images:true,winlink:false});
const initial=()=>[
  {namekey:'AREDN og==',aredn:true,meshtastic:false,meshcore:false,state:state()},
  {namekey:'%Existing og==',aredn:false,meshtastic:false,meshcore:false,state:state()}
];
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.CROW_CHROMIUM?{executablePath:process.env.CROW_CHROMIUM}:{})});
  let passed=0,failed=0;
  async function check(name,data,run) {
    const context=await browser.newContext();
    await context.route('**/*',route=>route.abort());
    const page=await context.newPage();
    page.setDefaultTimeout(5000);
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    try {
      await page.setContent(html);await page.addStyleTag({content:css});await page.addScriptTag({content:source});
      await page.evaluate(data=>{
        window.payloads=[];window.sockets=[];
        window.setTimeout=()=>1;window.clearTimeout=()=>{};
        window.WebSocket=class extends EventTarget {
          constructor(){super();this.readyState=0;window.sockets.push(this);}
          send(data){window.payloads.push(JSON.parse(data));}
          close(){this.readyState=3;}
          open(){this.readyState=1;this.dispatchEvent(new Event('open'));}
          emit(data){this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify(data)}));}
        };
        me={num:1,align:'right',format:'base64',colors:{fcolor:'#fff',bcolor:'#000'}};nodes[1]=me;
        startup();
        if(data!==null){sockets[0].open();sockets[0].emit({event:'channels',channels:data});}
      },data);
      await run(page);
      assert.deepEqual(errors,[],'no browser exceptions');
      passed++;console.log(`ok   - ${name}`);
    } catch(e) {failed++;console.error(`FAIL - ${name}: ${e.message}`);}
    finally {await context.close();}
  }
  try {
    await check('initial connection has an explanation and cannot save unseen channels',null,async page=>{
      await page.locator('.cog').click();await page.locator('.cog').click();
      assert.match(await page.locator('.config').innerText(),/Connecting to Crow/);
      assert.equal(await page.locator('.config button').count(),0);
      const saved=await page.evaluate(()=>{addChannel(-1);doneChannels();return payloads.filter(m=>m.cmd==='newchannels').length;});
      assert.equal(saved,0);
    });
    await check('an open socket alone does not authorize replacing the channel list',null,async page=>{
      await page.evaluate(()=>sockets[0].open());await page.locator('.cog').click();
      assert.equal(await page.locator('.config button').count(),0);
    });
    await check('first server data restores the requested editor with the AREDN preset',null,async page=>{
      await page.locator('.cog').click();
      await page.evaluate(data=>{sockets[0].open();sockets[0].emit({event:'channels',channels:data});},initial());
      assert.equal(await page.locator('.config form').count(),2);
      assert.equal(await page.locator('.config form').first().locator('input').first().isDisabled(),true);
      assert.equal(await page.evaluate(()=>payloads.filter(m=>m.cmd==='newchannels').length),0);
    });
    await check('an empty connected editor has an add control and safely creates its first channel',[],async page=>{
      await page.locator('.cog').click();
      assert.equal(await page.getByRole('button',{name:'Save',exact:true}).isDisabled(),true);
      await page.getByRole('button',{name:'Add channel',exact:true}).click();
      await page.getByPlaceholder('Name',{exact:true}).fill('%First');
      await page.getByRole('button',{name:'Save',exact:true}).click();
      assert.deepEqual(await page.evaluate(()=>payloads.filter(m=>m.cmd==='newchannels').map(m=>m.channels.map(c=>c.namekey))),[['%First og==']]);
    });
    await check('normal addition preserves existing channels and preset flags',initial(),async page=>{
      await page.locator('.cog').click();
      await page.locator('.config form').first().getByRole('button',{name:'+',exact:true}).click();
      await page.locator('.config form').nth(1).getByPlaceholder('Name',{exact:true}).fill('%Ops');
      await page.getByRole('button',{name:'Save',exact:true}).click();
      assert.deepEqual(await page.evaluate(()=>payloads.find(m=>m.cmd==='newchannels').channels.map(c=>c.namekey)),['AREDN og==','%Ops og==','%Existing og==']);
      assert.equal(await page.evaluate(()=>channels[0].aredn),true);
    });
    await check('typing a 12-character MeshCore channel name preserves its exact identity',initial(),async page=>{
      await page.locator('.cog').click();
      await page.locator('.config form').first().getByRole('button',{name:'+',exact:true}).click();
      const row=page.locator('.config form').nth(1);
      await row.getByPlaceholder('Name',{exact:true}).pressSequentially('CrowLatePriv');
      await row.getByPlaceholder('ID or Key',{exact:true}).fill('AQEBAQEBAQEBAQEBAQEBAQ==');
      assert.equal(await row.getByPlaceholder('Name',{exact:true}).inputValue(),'CrowLatePriv');
      await page.getByRole('button',{name:'Save',exact:true}).click();
      assert.deepEqual(await page.evaluate(()=>payloads.find(m=>m.cmd==='newchannels').channels.map(c=>c.namekey)),
        ['AREDN og==','CrowLatePriv AQEBAQEBAQEBAQEBAQEBAQ==','%Existing og==']);
    });
    await check('invalid rows cannot partially save or mutate existing channel state',initial(),async page=>{
      await page.locator('.cog').click();
      await page.evaluate(()=>{echannels[0].max=250;addChannel(0);doneChannels();});
      assert.match(await page.locator('#channel-config-error').innerText(),/every channel/);
      assert.equal(await page.evaluate(()=>payloads.filter(m=>m.cmd==='newchannels').length),0);
      assert.equal(await page.evaluate(()=>channels[0].state.max),150);
    });
    await check('a decodable but invalid-length key is rejected without losing other channels',initial(),async page=>{
      await page.locator('.cog').click();
      await page.evaluate(()=>{addChannel(0);echannels[1].name='Invalid';echannels[1].key='YWI=';doneChannels();});
      assert.equal(await page.evaluate(()=>payloads.filter(m=>m.cmd==='newchannels').length),0);
      assert.match(await page.locator('#channel-config-error').innerText(),/valid channel key/);
    });
    await check('disconnect prevents saving or queuing a stale replacement',initial(),async page=>{
      await page.locator('.cog').click();
      const result=await page.evaluate(()=>{
        sockets[0].readyState=3;sockets[0].dispatchEvent(new Event('close'));doneChannels();
        return {queued:sq.filter(m=>m.cmd==='newchannels').length,saved:payloads.filter(m=>m.cmd==='newchannels').length};
      });
      assert.deepEqual(result,{queued:0,saved:0});
      assert.match(await page.locator('.config').innerText(),/Connecting to Crow/);
    });
    await check('a closing socket cannot save before its close event arrives',initial(),async page=>{
      await page.locator('.cog').click();
      const result=await page.evaluate(()=>{
        sockets[0].readyState=2;doneChannels();
        return {queued:sq.filter(m=>m.cmd==='newchannels').length,saved:payloads.filter(m=>m.cmd==='newchannels').length};
      });
      assert.deepEqual(result,{queued:0,saved:0});
      assert.match(await page.locator('.config').innerText(),/Connecting to Crow/);
    });
    await check('reconnect refreshes settings from new server data, not an old draft',initial(),async page=>{
      await page.locator('.cog').click();
      await page.evaluate(data=>{
        echannels[1].name='%OldDraft';sockets[0].readyState=3;sockets[0].dispatchEvent(new Event('close'));
        startup();sockets[1].open();sockets[1].emit({event:'channels',channels:data});
      },[{...initial()[0]}, {...initial()[1],namekey:'%Server og=='}]);
      assert.deepEqual(await page.evaluate(()=>echannels.map(c=>c.name)),['AREDN','%Server']);
    });
    await check('another client channel update refreshes an open editor',initial(),async page=>{
      await page.locator('.cog').click();
      await page.evaluate(data=>sockets[0].emit({event:'channels',channels:data}),[...initial(),{...initial()[1],namekey:'%Remote og=='}]);
      assert.equal(await page.locator('.config form').count(),3);
    });
  } finally {await browser.close();}
  console.log(`${passed} passed, ${failed} failed`);process.exitCode=failed?1:0;
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
