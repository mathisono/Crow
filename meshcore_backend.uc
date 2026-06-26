import * as udp from "meshcore";
import * as api from "meshcore_tcp_api";

let active = null;
let activeName = null;
let lastConfig = null;
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

function hasTcpConfig(config)
{
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    return mode === "api" || mode === "tcp-api" || mode === "companion-api" ||
        config.meshcore_tcp_api?.enabled === true;
}

function hasUdpConfig(config)
{
    return !!config.meshcore && config.meshcore.enabled !== false;
}

function candidateStatus(key, label, transport, configured, isActive, host, port)
{
    const socketHandle = isActive ? active?.handle() : null;
    let state = "not-configured";
    if (configured && !isActive) {
        state = "configured-inactive";
    }
    else if (configured && isActive) {
        state = socketHandle ? (transport === "udp" ? "listening" : "connected") : "enabled-no-socket";
    }

    return {
        family: "meshcore",
        key: key,
        label: label,
        transport: transport,
        configured: configured,
        active: isActive,
        state: state,
        host: host,
        port: port,
        socket: socketHandle !== null,
        pending_rx: 0
    };
}

export function setup(config)
{
    lastConfig = config;
    active = null;
    activeName = null;
    enabled = false;

    if (wantsApi(config)) {
        active = api;
        activeName = "tcp";
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

export function backendStatus()
{
    const cfg = lastConfig ?? {};
    const out = [];

    push(out, candidateStatus(
        "meshcore.udp",
        "MeshCore UDP multicast",
        "udp",
        hasUdpConfig(cfg),
        activeName === "udp" && enabled,
        "224.0.0.69",
        4402
    ));

    push(out, candidateStatus(
        "meshcore.tcp",
        "MeshCore TCP Companion API",
        "tcp",
        hasTcpConfig(cfg),
        activeName === "tcp" && enabled,
        cfg.meshcore_tcp_api?.host ?? "127.0.0.1",
        cfg.meshcore_tcp_api?.port ?? 4403
    ));

    return out;
};
