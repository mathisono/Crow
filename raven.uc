#!/usr/bin/ucode

const config = require("./config.uc");

config.setup();
for (;;) {
    config.tick();
}
