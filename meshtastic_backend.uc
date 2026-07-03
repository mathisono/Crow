import * as udp from "meshtastic";
import * as api from "meshtastic_API";

let active = null;
let activeName = null;
export let enabled = false;

export function registerProto(name, portnum, decode)
{
    udp.registerProto(name, portnum, decode);
    api.registerProto(name, portnum, decode);
};

function log0(fmt, ...args)
{
    DEBUG0("meshtastic_backend: " + fmt, ...args);
}

function wantsApi(config)
{
    const mode = config.meshtastic?.backend ?? config.meshtastic?.transport;
    if (mode === "api" || mode === "tcp" || mode === "tcp-api" || mode === "port-api") {
        return true;
    }
    if (mode === "udp") {
        return false;
    }
    if (config.meshtastic_api?.enabled === true || config.meshtastic_API?.enabled === true) {
        return true;
    }
    return false;
}

function wantsUdp(config)
{
    if (!config.meshtastic) {
        return false;
    }
    const mode = config.meshtastic?.backend ?? config.meshtastic?.transport;
    if (mode === "api" || mode === "tcp" || mode === "tcp-api" || mode === "port-api") {
        return false;
    }
    return config.meshtastic.enabled !== false;
}

export function setup(config)
{
    active = null;
    activeName = null;
    enabled = false;

    if (wantsApi(config)) {
        active = api;
        activeName = "tcp-port-api";
    }
    else if (wantsUdp(config)) {
        active = udp;
        activeName = "udp";
    }

    if (!active) {
        log0("disabled\n");
        return;
    }

    log0("selected %s backend\n", activeName);
    active.setup(config);
    enabled = !!active.enabled;
    if (!enabled) {
        log0("selected %s backend did not enable\n", activeName);
    }
};

export function shutdown()
{
    active?.shutdown();
};

export function handle()
{
    return active?.handle();
};

export function recv()
{
    return active?.recv();
};

export function send(msg)
{
    return active?.send(msg);
};

export function tick()
{
    active?.tick();
};

export function process(msg)
{
    active?.process(msg);
};

export function backendName()
{
    return activeName;
};
