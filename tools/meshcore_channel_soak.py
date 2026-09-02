#!/usr/bin/env python3
"""Passive MeshCore/Crow channel and RAM soak monitor.

Uses the public channel directory as a real-world baseline and observes the
already-running nodes. It does not save channel secrets or alter radios.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DIRECTORY_URL = "https://bayareameshcore.com/channels.json"


def parse_node_spec(spec):
    name, separator, ip = spec.partition("=")
    if not separator or not name or not ip:
        raise argparse.ArgumentTypeError("node must be NAME=IP")
    return name, ip


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def fetch_directory(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Crow-channel-soak/1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = json.load(response)
    names = [str(item["name"]) for item in data.get("channels", []) if item.get("name")]
    return {
        "url": url,
        "channel_count": len(names),
        "channel_names": names,
        "channel_names_sha256": hashlib.sha256("\n".join(names).encode()).hexdigest(),
    }


def probe_node(ip, password):
    # The probe intentionally returns no config, keys, message text, or passwords.
    node_probe = r'''
status=$(/etc/init.d/crow status 2>&1 | tr '\n' ' ')
pid=$(ps w | awk '/\/usr\/local\/crow\/crow\.uc/ && !/awk/ {print $1; exit}')
rss=0
if [ -n "$pid" ] && [ -r "/proc/$pid/status" ]; then
    rss=$(awk '/VmRSS:/{print $2; exit}' "/proc/$pid/status")
fi
available=$(awk '/MemAvailable:/{print $2; exit}' /proc/meminfo)
total=$(awk '/MemTotal:/{print $2; exit}' /proc/meminfo)
starts=$(logread 2>/dev/null | grep -c 'Starting up' || true)
errors=$(logread 2>/dev/null | grep -Eic 'meshcore recv:|out of memory|oom-killer|syntax error|fatal' || true)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$pid" "$total" "$available" "$rss" "$starts" "$errors"
'''
    remote = (
        "SSHPASS=" + shlex.quote(password)
        + " sshpass -e ssh -o StrictHostKeyChecking=no "
        + "-o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 2222 "
        + "root@" + ip + " " + shlex.quote(node_probe)
    )
    result = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=15", "mse-88", remote],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode:
        detail = result.stderr.strip().splitlines()[-1:] or ["probe failed"]
        raise RuntimeError("; ".join(detail))
    fields = result.stdout.strip().split("\t")
    if len(fields) != 7:
        raise RuntimeError("unexpected probe response")
    return {
        "status": fields[0].strip(),
        "pid": int(fields[1] or 0),
        "mem_total_kb": int(fields[2] or 0),
        "mem_available_kb": int(fields[3] or 0),
        "crow_rss_kb": int(fields[4] or 0),
        "startup_count_total": int(fields[5] or 0),
        "error_count_total": int(fields[6] or 0),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration-hours", type=float, default=24.0)
    parser.add_argument("--interval-seconds", type=float, default=60.0)
    parser.add_argument("--directory-url", default=DIRECTORY_URL)
    parser.add_argument("--output", required=True)
    parser.add_argument("--once", action="store_true")
    parser.add_argument(
        "--node", action="append", default=[], type=parse_node_spec,
        metavar="NAME=IP",
        help="node to monitor (repeatable), e.g. NODE1=10.0.0.2",
    )
    args = parser.parse_args()

    nodes = dict(args.node)
    if not nodes:
        parser.error("at least one --node NAME=IP is required")

    password = os.environ.get("CROW_NODE_PASSWORD")
    if not password:
        print("CROW_NODE_PASSWORD is required", file=sys.stderr)
        return 2

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() if args.once else time.time() + args.duration_hours * 3600
    baselines = {}
    directory = None

    with output.open("a", encoding="utf-8") as report:
        def write(record):
            report.write(json.dumps(record, sort_keys=True) + "\n")
            report.flush()

        try:
            directory = fetch_directory(args.directory_url)
            write({"kind": "start", "timestamp": utc_now(), **directory,
                   "duration_hours": args.duration_hours,
                   "interval_seconds": args.interval_seconds,
                   "nodes": nodes})
        except Exception as exc:
            write({"kind": "directory_error", "timestamp": utc_now(), "error": str(exc)})

        while True:
            for name, ip in nodes.items():
                record = {
                    "kind": "sample", "timestamp": utc_now(), "node": name, "ip": ip,
                    "directory_channel_count": directory["channel_count"] if directory else None,
                    "directory_channel_names_sha256": directory["channel_names_sha256"] if directory else None,
                }
                try:
                    probe = probe_node(ip, password)
                    baseline = baselines.setdefault(name, probe)
                    record.update(probe)
                    record["new_startups"] = max(0, probe["startup_count_total"] - baseline["startup_count_total"])
                    record["new_errors"] = max(0, probe["error_count_total"] - baseline["error_count_total"])
                    record["pid_changed"] = probe["pid"] != baseline["pid"]
                except Exception as exc:
                    record["probe_error"] = str(exc)
                write(record)

            if args.once or time.time() >= deadline:
                write({"kind": "complete", "timestamp": utc_now()})
                return 0
            time.sleep(max(1.0, args.interval_seconds))


if __name__ == "__main__":
    raise SystemExit(main())
