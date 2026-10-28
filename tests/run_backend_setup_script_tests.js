#!/usr/bin/env node
'use strict';
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const result = spawnSync('python3', [path.join(__dirname, 'backend_setup_sandbox.py')], {stdio:'inherit'});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
