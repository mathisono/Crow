# Crow Migration and Compatibility Notes

Status: **historical compatibility record**
Last reviewed: **2026-08-25**

The active development and release plan is [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md).

This document records the Raven-to-Crow migration decisions that still matter
for maintenance:

- Crow runtime/config/service paths are preferred for new installs and writes.
- Legacy Raven paths are read-only compatibility/import sources.
- Raven configuration import is schema-aware and preserves Crow defaults.
- Runtime data is copied only when the Crow destination is missing.
- Sysupgrade configuration is packaged under the generic `crow.conf` name.
- UI escaping and URL allowlisting are implemented directly in `ui/ui.js`.
- Strict Gatekeeper behavior is implemented; real RF validation remains pending.

## Current compatibility checks

Before changing migration or packaging code, verify:

```sh
node --check ui/ui.js
sh -n platforms/aredn/build.sh platforms/aredn/admin.sh \
  platforms/aredn/usb-setup.sh platforms/aredn/postinst \
  platforms/aredn/postinstall platforms/aredn/postupgrade \
  platforms/aredn/prerm
```

On a test node with a legacy Raven installation, verify that:

1. a missing Crow config is created from compatible Raven keys only;
2. an existing Crow config is never overwritten by Raven data;
3. Raven runtime directories are copied only when Crow destinations are absent;
4. `/etc/init.d/crow` remains the active service path;
5. sysupgrade preserves Crow configuration under the generic Crow filename.

Do not treat the old Raven migration as a reason to reintroduce Raven runtime
paths or the removed `ui-safe.js` overlay.
