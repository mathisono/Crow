// Experimental USB Serial Companion backend.
// Direct serial I/O is not available in the supported Crow ucode platform.
// This module intentionally remains disabled rather than pretending to work.

let cfg = null;
export let enabled = false;

function log0(fmt, ...args)
{
    DEBUG0("meshcore_serial_api: " + fmt, ...args);
}

export function setup(config)
{
    cfg = config?.meshcore_serial_api ?? {};
    enabled = false;
    if (cfg.enabled === true) {
        log0("serial transport not implemented on this platform; use validation script or serial TCP bridge\n");
    }
};

export function shutdown() {};
export function handle() {};
export function recv() { return null; };
export function send(msg) { return false; };
export function tick() {};
export function pending() { return 0; };
export function status()
{
    return {
        pending_rx: 0,
        device: cfg?.device ?? "/dev/ttyACM0",
        baud: cfg?.baud ?? 115200,
        frame_mode: cfg?.frame_mode ?? "auto",
        app_start_profile: cfg?.app_start_profile ?? "meshcore_cli",
        channel_discovery: cfg?.channel_discovery === true,
        state: cfg?.enabled === true ? "disabled-unavailable" : "not-configured"
    };
};
