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
    if (mode === "serial" || mode === "serial-api" || mode === "usb" || mode === "usb-api") {
        return true;
    }
    if (mode === "api" || mode === "tcp" || mode === "tcp-api" || mode === "companion-api") {
        return false;
    }
    if (mode === "udp") {
        return false;
    }
    // Preserve existing TCP precedence when both backends are configured;
    // select USB implicitly only when TCP is not enabled.
    return (config.meshcore_serial_api?.enabled === true || config.meshcore_usb_api?.enabled === true) &&
        config.meshcore_tcp_api?.enabled !== true;
}

function wantsUdp(config)
{
    if (!config.meshcore) {
        return false;
    }
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    if (mode === "api" || mode === "tcp" || mode === "tcp-api" || mode === "companion-api" ||
        mode === "serial" || mode === "serial-api" || mode === "usb" || mode === "usb-api") {
        return false;
    }
    return config.meshcore.enabled !== false;
}

function hasTcpConfig(config)
{
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    return mode === "api" || mode === "tcp" || mode === "tcp-api" || mode === "companion-api" ||
        config.meshcore_tcp_api?.enabled === true;
}

function hasSerialConfig(config)
{
    const mode = config.meshcore?.backend ?? config.meshcore?.transport;
    return mode === "serial" || mode === "serial-api" || mode === "usb" || mode === "usb-api" ||
        config.meshcore_serial_api?.enabled === true || config.meshcore_usb_api?.enabled === true;
}

function hasUdpConfig(config)
{
    return !!config.meshcore && config.meshcore.enabled !== false;
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

function ensureDefaultPublicChannel(config)
{
    ensureDefaultChannel(config, channel.meshcorePublicChannelNamekey(), "MeshCore~Public");
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
        sends_ok: detail.sends_ok,
        sends_failed: detail.sends_failed,
        direct_sends_ok: detail.direct_sends_ok,
        direct_sends_failed: detail.direct_sends_failed,
        channel_sends_ok: detail.channel_sends_ok,
        channel_sends_failed: detail.channel_sends_failed,
        responses_cached: detail.responses_cached,
        channel_discovery: detail.channel_discovery,
        channel_scans: detail.channel_scans,
        channel_discovery_requests: detail.channel_discovery_requests,
        channel_info_responses: detail.channel_info_responses,
        channel_discovery_timeouts: detail.channel_discovery_timeouts,
        channels_discovered: detail.channels_discovered,
        channels_updated: detail.channels_updated,
        group_receive_unverified: detail.group_receive_unverified,
        channel_provisions_ok: detail.channel_provisions_ok,
        channel_provisions_failed: detail.channel_provisions_failed,
        room_servers_added: detail.room_servers_added,
        room_logins_ok: detail.room_logins_ok,
        room_logins_failed: detail.room_logins_failed,
        log_data_frames: detail.log_data_frames,
        trace_data_frames: detail.trace_data_frames,
        telemetry_response_frames: detail.telemetry_response_frames,
        binary_response_frames: detail.binary_response_frames,
        control_data_frames: detail.control_data_frames,
        message_sent_frames: detail.message_sent_frames,
        ack_frames: detail.ack_frames,
        unknown_frames: detail.unknown_frames,
        unknown_frames_suppressed: detail.unknown_frames_suppressed,
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
        ensureDefaultPublicChannel(config);
        // Load the serial wrapper only when selected.  Keeping this import
        // lazy avoids the config -> commands -> discovery -> TCP module cycle
        // on ucode versions that reject parallel module initialization.
        active = serialApi;
        activeName = "serial";
    }
    else if (wantsApi(config)) {
        ensureDefaultPublicChannel(config);
        active = api;
        activeName = "tcp";
    }
    else if (wantsUdp(config)) {
        ensureDefaultPublicChannel(config);
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

export function addRoomServer(name, publicKeyB64, password)
{
    if (active?.addRoomServer) return active.addRoomServer(name, publicKeyB64, password);
    return false;
};

export function loginRoomServer(target)
{
    if (active?.loginRoomServer) return active.loginRoomServer(target);
    return false;
};

export function provisionPrivateChannel(slot, name, keyB64)
{
    if (active?.provisionPrivateChannel) return active.provisionPrivateChannel(slot, name, keyB64);
    return false;
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

    const serialConfig = cfg.meshcore_serial_api ?? cfg.meshcore_usb_api ?? {};
    const serialStatus = candidateStatus(
        "meshcore.serial",
        "MeshCore USB Serial Companion API",
        "serial",
        hasSerialConfig(cfg),
        activeName === "serial" && enabled,
        serialConfig.device ?? "/dev/ttyACM0",
        serialConfig.baud ?? 115200
    );
    serialStatus.device = serialConfig.device ?? "/dev/ttyACM0";
    serialStatus.baud = serialConfig.baud ?? 115200;
    push(out, serialStatus);

    return out;
};

export function _test_ensure_default_public_channel(config)
{
    ensureDefaultPublicChannel(config);
};

export function _test_backend_choice(config)
{
    if (wantsSerial(config)) return "serial";
    if (wantsApi(config)) return "tcp";
    if (wantsUdp(config)) return "udp";
    return null;
};
