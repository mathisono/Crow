import * as udp from "meshtastic";
import * as api from "meshtastic_API";
import * as channel from "channel";

let active = null;
let activeName = null;
let lastConfig = null;
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

function hasTcpConfig(config)
{
    const mode = config.meshtastic?.backend ?? config.meshtastic?.transport;
    return mode === "api" || mode === "tcp-api" || mode === "port-api" ||
        config.meshtastic_api?.enabled === true ||
        config.meshtastic_API?.enabled === true;
}

function hasUdpConfig(config)
{
    return !!config.meshtastic && config.meshtastic.enabled !== false;
}

function tcpConfig(config)
{
    return config.meshtastic_api ?? config.meshtastic_API ?? {};
}

function ensureDefaultChannel(config, namekey, label)
{
    if (!config.channels) config.channels = [];
    for (let i = 0; i < length(config.channels); i++) {
        if (config.channels[i].namekey === namekey) {
            config.channels[i].label = label;
            return;
        }
    }
    push(config.channels, { namekey: namekey, label: label });
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
        family: "meshtastic",
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
        ensureDefaultChannel(config, channel.meshtasticPublicChannelNamekey(), "Meshtastic~Public");
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
    const tc = tcpConfig(cfg);
    const out = [];

    push(out, candidateStatus(
        "meshtastic.udp",
        "Meshtastic UDP multicast",
        "udp",
        hasUdpConfig(cfg),
        activeName === "udp" && enabled,
        "224.0.0.69",
        4403
    ));

    push(out, candidateStatus(
        "meshtastic.tcp",
        "Meshtastic TCP Port API",
        "tcp",
        hasTcpConfig(cfg),
        activeName === "tcp" && enabled,
        tc.host ?? null,
        tc.port ?? 4403
    ));

    return out;
};
