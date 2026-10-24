#!/usr/bin/env node
'use strict';

// Real DOM checks: run with Playwright and Chromium, not a markup mock.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
let chromium;
try {
    ({ chromium } = require(process.env.CROW_PLAYWRIGHT_MODULE || 'playwright'));
} catch (error) {
    if (process.env.CROW_PLAYWRIGHT_MODULE || error.code !== 'MODULE_NOT_FOUND') throw error;
    console.log('SKIP: browser rendering tests need Playwright (see tests/README.md)');
    process.exit(0);
}

(async () => {
    const browser = await chromium.launch({
        headless: true,
        ...(process.env.CROW_CHROMIUM ? { executablePath: process.env.CROW_CHROMIUM } : {})
    });
    let passed = 0;
    let failed = 0;
    try {
        const page = await browser.newPage();
        await page.setContent('<div id="texts"></div><div id="fixture"></div><div id="left"></div>');
        const source = fs.readFileSync(path.join(__dirname, '../ui/ui.js'), 'utf8')
            .replace('document.addEventListener("DOMContentLoaded", startup);', '');
        await page.addScriptTag({ content: source });
        await page.evaluate(() => {
            window.joinCalls = [];
            cmd = text => window.joinCalls.push(text);
            nodes[1] = { num: 1, short_name: 'TEST', long_name: 'Test', colors: { fcolor: '#fff', bcolor: '#000' } };
        });
        async function check(name, run) {
            try {
                await run();
                passed++;
                console.log(`ok   - ${name}`);
            } catch (error) {
                failed++;
                console.error(`FAIL - ${name}: ${error.message}`);
            }
        }

        await check('attribute values round-trip quotes without adding attributes', async () => {
            const result = await page.evaluate(() => {
                const value = '" data-injected="yes\' & < > `';
                const el = N(`<div data-namekey="${attr(value)}"></div>`);
                return { exact: el.dataset.namekey === value, count: el.attributes.length };
            });
            assert.deepEqual(result, { exact: true, count: 1 });
        });

        await check('quoted channel names keep their complete selection handler', async () => {
            const result = await page.evaluate(() => {
                const namekey = '#Test"quoted key';
                const el = N(`<div onclick="${attr(`showNamekey(${JSON.stringify(namekey)})`)}"></div>`);
                let selected;
                showNamekey = value => { selected = value; };
                el.click();
                return selected === namekey;
            });
            assert.equal(result, true);
        });

        await check('channel and node rows select exactly once through delegated clicks', async () => {
            const result = await page.evaluate(() => {
                const selected = [];
                showNamekey = value => selected.push(value);
                I('left').innerHTML = htmlChannel({ namekey: '#Test"quoted key', state: { count: 0 } })
                    + htmlNode(nodes[1]);
                I('left').querySelector('.channel .t').click();
                I('left').querySelector('.node .l').click();
                return selected;
            });
            assert.deepEqual(result, ['#Test"quoted key', 'DirectMessages 1']);
        });

        await check('command replies render clickable and read-only channel entries', async () => {
            const result = await page.evaluate(() => {
                I('texts').innerHTML = '';
                commandReply({ reply: ['<b>Channels</b>', '&nbsp;', '<div class="cj">Primary</div>', '<div class="cj" onclick=\'cmd("/channels join #test key")\'>#test key</div>'] });
                const root = I('texts');
                const buttons = root.querySelectorAll('.cj');
                buttons[1]?.click();
                return { count: buttons.length, command: window.joinCalls.at(-1), raw: root.innerText.includes('<div'), heading: root.querySelector('b')?.innerText };
            });
            assert.deepEqual(result, { count: 2, command: '/channels join #test key', raw: false, heading: 'Channels' });
        });

        await check('discovery /join commands dispatch once with literal arguments', async () => {
            const result = await page.evaluate(() => {
                const command = '/join #test"quoted';
                const handler = `cmd(${JSON.stringify(command)})`;
                const raw = `<div class="cj" onclick='${handler}'>join</div>`;
                I('fixture').innerHTML = renderChannelsList(raw);
                window.joinCalls = [];
                I('fixture').firstElementChild.click();
                return window.joinCalls;
            });
            assert.deepEqual(result, ['/join #test"quoted']);
        });

        for (const handler of [
            'window.__unsafe = true',
            'cmd("/channels join #test");window.__unsafe = true',
            'cmd("/storage format")',
            'cmd("/join #test\\n/leave #other")'
        ]) {
            await check(`channel renderer rejects non-join code: ${handler}`, async () => {
                const result = await page.evaluate(handler => {
                    window.__unsafe = false;
                    window.joinCalls = [];
                    const raw = `<div class="cj" onclick='${handler}'>test</div>`;
                    I('fixture').innerHTML = renderChannelsList(raw);
                    I('fixture').firstElementChild.click();
                    return { unsafe: window.__unsafe, calls: window.joinCalls.length, handler: I('fixture').firstElementChild.hasAttribute('onclick') };
                }, handler);
                assert.deepEqual(result, { unsafe: false, calls: 0, handler: false });
            });
        }

        await check('command entries discard untrusted nested markup and attributes', async () => {
            const result = await page.evaluate(() => {
                const raw = '<div class="cj" onmouseover="window.__unsafe=true"><img src=x onerror="window.__unsafe=true">&lt;img&gt; &amp; name</div>';
                I('fixture').innerHTML = renderChannelsList(raw);
                return { text: I('fixture').textContent, images: I('fixture').querySelectorAll('img').length, handlers: I('fixture').querySelectorAll('[onmouseover],[onerror]').length };
            });
            assert.deepEqual(result, { text: '<img> & name', images: 0, handlers: 0 });
        });

        await check('ordinary chat keeps channel-looking markup inert and visible', async () => {
            const result = await page.evaluate(() => {
                const payload = '<div class="cj" onclick="window.__unsafe=true">message</div>';
                I('fixture').innerHTML = htmlText({ id: 5, from: 1, when: 0, text: payload }, false);
                return { literal: I('fixture').textContent.includes(payload), controls: I('fixture').querySelectorAll('.cj').length };
            });
            assert.deepEqual(result, { literal: true, controls: 0 });
        });

        await check('command text preserves only supported formatting', async () => {
            const result = await page.evaluate(() => {
                I('fixture').innerHTML = htmlCommand(['<b>bold</b> <i>active</i> &mdash; &lt;name&gt; <img src=x onerror="window.__unsafe=true">']);
                return { bold: I('fixture').querySelector('b')?.textContent, italic: I('fixture').querySelector('i')?.textContent, images: I('fixture').querySelectorAll('img').length, placeholder: I('fixture').textContent.includes('<name>') };
            });
            assert.deepEqual(result, { bold: 'bold', italic: 'active', images: 0, placeholder: true });
        });
    } finally {
        await browser.close();
    }
    console.log(`\n${passed} browser checks passed, ${failed} failed`);
    process.exitCode = failed ? 1 : 0;
})().catch(error => { console.error(error); process.exitCode = 1; });
