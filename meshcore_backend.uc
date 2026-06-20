import * as udp from "meshcore";
import * as api from "meshcore_tcp_api";

let active = null;
let activeName = null;
export let enabled = false;

function log0(fmt, ...args)
{
    DEBUG0("meshcore_backend: " + fmt, ...args);
}

function wantsApi(config)
{
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    if (mode === "api" || mode === "tcp-api" || mode === "companion-api") {
        return true;
    }
    if (config.meshcore_tcp_api?.enabled === true) {
        return config.meshcore?.enabled === false || !config.meshcore;
    }
    return false;
}

function wantsUdp(config)
{
    if (!config.meshcore) {
        return false;
    }
    return config.meshcore.enabled !== false;
}

export function setup(config)
{
    active = null;
    activeName = null;
    enabled = false;

    if (wantsApi(config)) {
        active = api;
        activeName = "tcp-api";
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
