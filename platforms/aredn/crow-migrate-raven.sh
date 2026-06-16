#!/bin/sh
# One-time compatibility importer for systems upgrading from Raven to Crow.
# Crow owns /etc/crow.conf, /etc/crow.conf.override, and /usr/local/crow.
# Legacy Raven paths are used only as import sources when Crow files do not exist.

set -eu

CROW_CONF=/etc/crow.conf
CROW_OVERRIDE=/etc/crow.conf.override
RAVEN_CONF=/etc/raven.conf
RAVEN_OVERRIDE=/etc/raven.conf.override
DEFAULT_CROW_CONF=/usr/local/crow/crow.conf

copy_tree_if_missing() {
    src="$1"
    dst="$2"
    if [ -d "$src" ] && [ ! -d "$dst" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        echo "crow-migrate: imported $src -> $dst"
    fi
}

merge_json_if_possible() {
    base="$1"
    old="$2"
    out="$3"
    python3 - "$base" "$old" "$out" <<'PY' || return 1
import json
import sys

base_path, old_path, out_path = sys.argv[1:4]
with open(base_path) as f:
    base = json.load(f)
with open(old_path) as f:
    old = json.load(f)

# Only migrate stable user-facing settings. Do not blindly carry every old key
# because Crow may change backend/schema details independently of Raven.
allow_top = {
    "debug", "role", "callsign", "location", "messages", "channels",
    "storage", "telemetry", "ui", "aprs", "meshtastic", "meshcore",
    "arednmesh", "websocket", "platform_aredn", "platform_debian"
}

for key in allow_top:
    if key in old:
        base[key] = old[key]

# Ensure Crow's current storage default wins unless Raven explicitly had storage.
if "storage" not in old and "storage" in base:
    base["storage"]["mountpoint"] = "/mnt/crow"
    base["storage"]["label"] = "CROWDATA"

# Strict gatekeeper is Crow-owned. Keep default off unless user already configured it.
if "strict_gatekeeper" in old:
    base["strict_gatekeeper"] = old["strict_gatekeeper"]
elif "strict_gatekeeper" not in base:
    base["strict_gatekeeper"] = {
        "enabled": False,
        "gateway_callsign": base.get("callsign", "N0CALL"),
        "allowed_callsigns": []
    }

with open(out_path, "w") as f:
    json.dump(base, f, indent=4)
    f.write("\n")
PY
}

if [ ! -e "$CROW_CONF" ] && [ -e "$RAVEN_CONF" ] && [ -e "$DEFAULT_CROW_CONF" ]; then
    tmp="${CROW_CONF}.tmp.$$"
    if merge_json_if_possible "$DEFAULT_CROW_CONF" "$RAVEN_CONF" "$tmp"; then
        mv "$tmp" "$CROW_CONF"
        echo "crow-migrate: merged compatible Raven config keys into $CROW_CONF"
    else
        rm -f "$tmp"
        echo "crow-migrate: Raven config was not valid JSON; leaving Crow default in place"
    fi
fi

if [ ! -e "$CROW_OVERRIDE" ] && [ -e "$RAVEN_OVERRIDE" ]; then
    tmp="${CROW_OVERRIDE}.tmp.$$"
    if merge_json_if_possible "$DEFAULT_CROW_CONF" "$RAVEN_OVERRIDE" "$tmp"; then
        mv "$tmp" "$CROW_OVERRIDE"
        echo "crow-migrate: merged compatible Raven override keys into $CROW_OVERRIDE"
    else
        rm -f "$tmp"
        echo "crow-migrate: Raven override was not valid JSON; not importing override"
    fi
fi

# Preserve old local runtime data only when Crow data has not been created yet.
copy_tree_if_missing /usr/local/raven/data /usr/local/crow/data
copy_tree_if_missing /usr/local/raven/store /usr/local/crow/store
copy_tree_if_missing /usr/local/raven/winlink /usr/local/crow/winlink

# Preserve USB/external storage data if the old mountpoint exists and the new one does not.
copy_tree_if_missing /mnt/raven /mnt/crow

exit 0
