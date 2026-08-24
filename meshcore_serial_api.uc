// MeshCore USB Serial Companion backend.
//
// The Companion protocol is identical on the USB serial and TCP transports:
// framed '<' commands, framed '>' responses, the 0x83/0x0A pull queue, and
// the same direct/channel message layouts.  The implementation lives in
// meshcore_tcp_api.uc so the two transports cannot acquire different TX/RX
// behavior.  This module supplies the backend-specific lifecycle name.

import * as api from "meshcore_tcp_api";

export let enabled = false;

export function setup(config)
{
    api.setupSerial(config);
    enabled = !!api.enabled;
};

export function shutdown()
{
    api.shutdown();
    enabled = false;
};

export function handle()
{
    return api.handle();
};

export function recv()
{
    return api.recv();
};

export function send(msg)
{
    return api.send(msg);
};

export function tick()
{
    api.tick();
};

export function process(msg)
{
    api.process(msg);
};

export function pending()
{
    return api.pending();
};

export function status()
{
    return api.status();
};

