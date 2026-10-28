# Historical MeshCore channel soak evidence

The following records the August 2026 baseline; it is not a fresh-install
qualification of a later release.

## MeshCore channel soak benchmark

The public channel directory at
`https://bayareameshcore.com/channels/` (machine-readable source:
`channels.json`) is the real-world baseline for this test. The directory
contained **20 public channels** when the soak began on 2026-08-27. Those 20
entries are a traffic reference, not 20 radio slots: MeshCore exposes slots
0–7, and BB5/Hub5 currently use two mapped slots (public plus the private
test channel).

The passive monitor is used first for short five-minute soaks:

```bash
mkdir -p test-artifacts
export CROW_NODE_PASSWORD='(operator-provided node password)'
python3 tools/meshcore_channel_soak.py \
  --node NODE1=10.0.0.2 \
  --duration-hours 0.083333 \
  --interval-seconds 30 \
  --output test-artifacts/meshcore-channel-soak-5m-2slot.jsonl
```

It records the directory count/name digest, Crow service status, process RSS,
available RAM, restart count, and fatal/OOM/ucode error deltas. It does not
save channel secrets, inject traffic, alter radio channels, or retain message
contents. Run each soak alongside normal live MeshCore traffic. The raw
reports are ignored by Git; summarize the completed results in this section
before a release.

Acceptance criteria:

- both Crow services remain running for the full 24 hours;
- no new ucode, fatal, OOM, or kernel out-of-memory events;
- no unexplained Crow restarts;
- available RAM never reaches zero, with any sustained low-memory period
  investigated before release;
- channel handling is reported as mapped radio slots, separately from the
  public directory's channel count.

Preliminary live baseline at test start:

| Node | Crow | Available RAM | Crow RSS | Mapped MeshCore slots |
|---|---|---:|---:|---:|
| BB5 | running | ~7.0 MiB | not yet stable | 2 |
| Hub5 | running | ~21.3 MiB | not yet stable | 2 |

Completed five-minute two-slot soak, 2026-08-27 19:31–19:36 PDT, using 30
second samples (10 samples per node):

| Node | Service samples | Available RAM range | Crow RSS range | Probe failures | New errors | PID changes |
|---|---:|---:|---:|---:|---:|---:|
| BB5 | 10/10 running | 7.9–9.9 MiB | 3.9–4.1 MiB | 0 | 0 | 0 |
| Hub5 | 10/10 running | 25.5–27.4 MiB | 4.6 MiB | 0 | 0 | 0 |

The completed run is a five-minute, two-mapped-slot soak. Short soaks are
smoke tests, not the final release gate. A controlled slot-ramp test is
required to claim a maximum beyond the current two-slot live configuration;
adding directory entries alone would not create real MeshCore traffic. After
the short-soak series passes, repeat the selected maximum configuration for
24 hours before release.

For details, see [Channel Management Guide](CHANNELS.md).
