#!/bin/sh
# Crow runner wrapper - sets UCODE_REQUIRE_PATH and executes router.uc
# This is necessary for AREDN ucode module resolution
exec env UCODE_REQUIRE_PATH="/usr/share/ucode/?.uc:/usr/local/crow/?.uc" /usr/bin/ucode /usr/local/crow/router.uc "$@"
