#!/bin/sh
# Lightweight AREDN watchdog.  It intentionally uses only BusyBox/POSIX tools.

SERVICE=${CROW_SERVICE:-/etc/init.d/crow}
HEARTBEAT=${CROW_HEARTBEAT:-/tmp/crow-heartbeat}
ENABLED_LINK=${CROW_ENABLED_LINK:-/etc/rc.d/S99crow}
INTERVAL=${CROW_WATCHDOG_INTERVAL:-60}
STALE_AFTER=${CROW_WATCHDOG_STALE_AFTER:-180}
TAG=${CROW_WATCHDOG_TAG:-crow-watchdog}

log_event() {
    logger -t "$TAG" "$*" 2>/dev/null || echo "$TAG: $*" >&2
}

crow_enabled() {
    [ -e "$ENABLED_LINK" ]
}

crow_pid() {
    ps w 2>/dev/null | awk '
        $0 ~ /\/usr\/local\/crow\/crow\.uc([[:space:]]|$)/ ||
        $0 ~ /\/usr\/local\/crow\/router\.uc([[:space:]]|$)/ { print $1; exit }'
}

restart_crow() {
    log_event "$1; restarting Crow"
    "$SERVICE" restart >/dev/null 2>&1
}

check_once() {
    # Respect an intentional /etc/init.d/crow disable.
    if ! crow_enabled; then
        return 0
    fi

    pid=$(crow_pid)
    if [ -z "$pid" ]; then
        restart_crow "Crow process is missing"
        return 0
    fi

    heartbeat=$(cat "$HEARTBEAT" 2>/dev/null)
    case "$heartbeat" in
        ''|*[!0-9]*)
            restart_crow "Crow heartbeat is missing or invalid"
            return 0
            ;;
    esac

    now=$(date +%s)
    case "$now" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # Do not restart solely because the clock moved backwards.
    if [ "$heartbeat" -le "$now" ] && [ $((now - heartbeat)) -gt "$STALE_AFTER" ]; then
        restart_crow "Crow heartbeat is stale (${now}-${heartbeat}s)"
    fi
}

case "${1:-}" in
    --once)
        check_once
        ;;
    --loop)
        while :; do
            check_once
            sleep "$INTERVAL"
        done
        ;;
    *)
        echo "usage: $0 --once|--loop" >&2
        exit 2
        ;;
esac
