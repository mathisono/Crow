#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

for test_file in tests/run_*.js; do
    printf '\n==> %s\n' "$test_file"
    node "$test_file"
done

# Node runners invoke their mirrored ucode fixture themselves. Run the
# remaining ucode-only suites here so a host with ucode gets full coverage.
if command -v ucode >/dev/null 2>&1; then
    for test_file in \
        tests/test_channel_parser.uc \
        tests/test_frame_detection.uc \
        tests/test_gatekeeper_acl.uc \
        tests/test_key_derivation.uc
    do
        printf '\n==> %s\n' "$test_file"
        ucode -I . "$test_file"
    done
else
    printf '\nucode not found; skipped 4 standalone ucode suites\n'
fi
