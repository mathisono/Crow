const timers = require("timers");
const router = require("router");
const message = require("message");
const node = require("node");
const nodedb = require("nodedb");
const channel = require("channel");
const telemetry = require("telemetry");

let weewxurl;

export function setup(config)
{
    weewxurl = config.telemetry?.environmental_weewx?.url;
    if (weewxurl) {
        timers.setInterval("environmental_metrics", 60, config.telemetry?.environmental_weewx?.interval ?? telemetry.DEFAULT_INTERVAL);
    }
};

export function tick()
{
    if (timers.tick("environmental_metrics")) {
        try {
            const j = json(platform.fetch(weewxurl, 2));
            const c = j.current;
            const d = j.day;
            const telemetry = channel.getTelemetryChannels();
            for (let i = 0; i < length(telemetry); i++) {
                router.queue(message.createMessage(null, null, telemetry[i].namekey, "telemetry", {
                    time: time(),
                    environment_metrics: {
                        temperature: telemetry.convert("C", c.temperature),
                        relative_humidity: c.humidity?.value,
                        barometric_pressure: telemetry.convert("hPA", c.barometer),
                        wind_direction: c["wind direction"]?.value,
                        wind_speed: telemetry.convert("m/s", c["wind speed"]),
                        wind_gust: telemetry.convert("m/s", c["wind gust"]),
                        rainfall_1h: telemetry.convert("mm/h", c["rain rate"]),
                        rainfall_24h: telemetry.convert("mm", d["rain total"])
                    }
                }));
            }
        }
        catch (_) {
        }
    }
};

export function process(msg)
{
    if (msg.data?.telemetry?.environment_metrics && node.forMe(msg)) {
        nodedb.updateEnvironmentMetrics(msg.from, msg.data.telemetry.environment_metrics);
    }
};
