import * as udp from "meshcore";
import * as api from "meshcore_tcp_api";
import * as serialApi from "meshcore_serial_api";
import * as channel from "channel";

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
    if (mode === "api" || mode === "tcp" || mode === "tcp-api" || mode === "companion-api") {
        return true;
    }
    if (mode === "udp") {
        return false;
    }
    if (config.meshcore_tcp_api?.enabled === true) {
        return true;
    }
    return false;
}

function wantsSerial(config)
{
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    return (mode === "serial" || mode === "serial-api") &&
        config.meshcore_serial_api?.enabled === true;
}

function wantsUdp(config)
{
    if (!config.meshcore) {
        return false;
    }
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    if (mode === "api" || mode === "tcp" || mode === "tcp-api" || mode === "companion-api" || mode === "serial" || mode === "serial-api") {
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

function hasSerialConfig(config)
{
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    return mode === "serial" || mode === "serial-api" || config.meshcore_serial_api?.enabled === true;
}

function hasUdpConfig(config)
{
    return !!config.meshcore && config.meshcore.enabled !== false;
}

function meshcoreBackendLabel(transport)
{
    if (transport === "udp") return "meshcore-udp[udp]";
    if (transport === "serial") return "MeshCore USB Serial Companion API";
    return "meshcore-tcp[tcp]";
}

function ensureDefaultChannel(config, namekey, label, backend)
{
    if (!config.channels) config.channels = [];
    for (let i = 0; i < length(config.channels); i++) {
        if (config.channels[i].namekey === namekey) {
            config.channels[i].label = label;
            if (backend != null) {
                config.channels[i].backend = backend;
            }
            return;
        }
    }
    const chan = { namekey: namekey, label: label };
    if (backend != null) {
        chan.backend = backend;
    }
    push(config.channels, chan);
}

function candidateStatus(key, label, transport, configured, isActive, host, port)
{
    const socketHandle = isActive ? active?.handle() : null;
    const detail = isActive && active?.status ? active.status() : {};
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
        pending_rx: detail.pending_rx ?? 0,
        max_pending_rx: detail.max_pending_rx,
        connects: detail.connects,
        disconnects: detail.disconnects,
        handshakes_sent: detail.handshakes_sent,
        bytes_rx: detail.bytes_rx,
        frames_in: detail.frames_in,
        frames_decoded: detail.frames_decoded,
        self_info: detail.self_info,
        message_waiting: detail.message_waiting,
        sync_requests: detail.sync_requests,
        sync_backpressure: detail.sync_backpressure,
        no_more_messages: detail.no_more_messages,
        syncing_messages: detail.syncing_messages,
        sync_request_in_flight: detail.sync_request_in_flight,
        sync_paused_backpressure: detail.sync_paused_backpressure,
        commands_sent: detail.commands_sent,
        responses_cached: detail.responses_cached,
        channel_discovery: detail.channel_discovery,
        channel_discovery_requests: detail.channel_discovery_requests,
        channel_info_responses: detail.channel_info_responses,
        channels_discovered: detail.channels_discovered,
        channels_updated: detail.channels_updated,
        last_rx_time: detail.last_rx_time,
        last_cmd: detail.last_cmd
    };
}

export function setup(config)
{
    lastConfig = config;
    active = null;
    activeName = null;
    enabled = false;

    if (wantsSerial(config)) {
        active = serialApi;
        activeName = "serial";
    }
    else if (wantsApi(config)) {
        active = api;
        activeName = "tcp";
    }
    else if (wantsUdp(config)) {
        ensureDefaultChannel(config, channel.meshcorePublicChannelNamekey(), "MeshCore~Public", "meshcore.udp");
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
    if (active) active.shutdown();
};

export function handle()
{
    if (active) return active.handle();
};

export function recv()
{
    if (active) return active.recv();
};

export function send(msg)
{
    if (active) return active.send(msg);
};

export function tick()
{
    if (active) active.tick();
};

export function process(msg)
{
    if (active) active.process(msg);
};

export function pending()
{
    if (active?.pending) return active.pending();
    return 0;
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
        meshcoreBackendLabel("udp"),
        "udp",
        hasUdpConfig(cfg),
        activeName === "udp" && enabled,
        "224.0.0.69",
        4402
    ));

    const serialDetail = serialApi.status ? serialApi.status() : {};
    push(out, {
        family: "meshcore", key: "meshcore.serial",
        label: "MeshCore USB Serial Companion API", transport: "serial",
        device: cfg.meshcore_serial_api?.device ?? "/dev/ttyACM0",
        baud: cfg.meshcore_serial_api?.baud ?? 115200,
        configured: hasSerialConfig(cfg),
        active: activeName === "serial" && enabled,
        state: serialDetail.state ?? "not-configured",
        pending_rx: serialDetail.pending_rx ?? 0,
        max_pending_rx: cfg.meshcore_serial_api?.max_pending_rx ?? 4,
        channel_discovery: cfg.meshcore_serial_api?.channel_discovery === true
    });

    push(out, candidateStatus(
        "meshcore.tcp",
        meshcoreBackendLabel("tcp"),
        "tcp",
        hasTcpConfig(cfg),
        activeName === "tcp" && enabled,
        cfg.meshcore_tcp_api?.host ?? "127.0.0.1",
        cfg.meshcore_tcp_api?.port ?? 4403
    ));

    return out;
};

export function getBackendNames()
{
    const out = [];
    const status = backendStatus();
    for (let i = 0; i < length(status); i++) {
        const b = status[i];
        if (b.configured || b.active) {
            push(out, { key: b.key, label: b.label });
        }
    }
    return out;
};
