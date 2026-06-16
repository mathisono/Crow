# Crow migration/security patch plan

This repository is being migrated from Raven-compatible paths to native Crow paths while retaining one-time Raven import compatibility for existing installs.

Planned patch set:

1. Harden AREDN image CGI path handling.
2. Harden UI string/url rendering.
3. Add WebSocket frame/message size limits.
4. Tighten strict-gatekeeper callsign normalization and document config.
5. Move Crow runtime/config/service paths to Crow names, with first-install import from legacy Raven locations.
