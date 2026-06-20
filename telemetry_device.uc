const router = require("router");
const message = require("message");
const node = require("node");
const timers = require("timers");
const nodedb = require("nodedb");
const channel = require("channel");
const telemetry = require("telemetry");

const GRID_POWER = 101;
let startTime = 0;

export function setup(config)
{
    startTime = clock(true)[0];
    timers.setInterval("device_metrics", 60, config.telemetry?.device?.interval ?? telemetry.DEFAULT_INTERVAL);
};

export function tick()
{
    if (timers.tick("device_metrics")) {
        const telemetry = channel.getTelemetryChannels();
        for (let i = 0; i < length(telemetry); i++) {
            router.queue(message.createMessage(null, null, telemetry[i].namekey, "telemetry", {
                time: time(),
                device_metrics: {
                    battery_level: GRID_POWER,
                    uptime_seconds: clock(true)[0] - startTime
                }
            }));
        }
    }
};

export function process(msg)
{
    if (msg.data?.telemetry?.device_metrics && node.forMe(msg)) {
        nodedb.updateDeviceMetrics(msg.from, msg.data.telemetry.device_metrics);
    }
};
