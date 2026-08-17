# AREDN Deployment Notes - Module Resolution History

**Date:** 2026-06-20  
**Issue:** Module resolution on AREDN's ucode interpreter  
**Status:** Historical note. The current branch restored `import`/`export`
module flow in commit `778433f`; do not treat the older `require()` conversion
below as the current source layout.

---

## Problem Summary

AREDN's ucode interpreter has limitations with ES6 `import` statements and module path resolution. Direct deployments to `/usr/local/crow/` result in:

```
Syntax error: Exports may only appear at top level of a module
In router.uc, line 18, byte 1:
```

This occurs because the ucode module loader can't resolve custom import paths outside `/usr/share/ucode/`.

---

## Historical Solution 1: Symlink + Require()

### Step 1: Install package

```bash
opkg install crow_0.0.1-r*.ipk
```

### Step 2: Create symlinks to standard ucode path

```bash
# Link all Crow modules to AREDN's standard module directory
ln -sf /usr/local/crow/*.uc /usr/share/ucode/

# Verify
ls -la /usr/share/ucode/ | grep crow
```

### Step 3: Router loaded with require()

Older packages briefly included source code converted from ES6 `import` to
`require()` statements, which worked with AREDN's ucode when modules were in
`/usr/share/ucode/`. Current source files use `import`/`export` again.

### Step 4: Restart service

```bash
/etc/init.d/crow restart
```

---

## Solution 2: Environment Variable (For Testing/Development)

Run Crow with `UCODE_REQUIRE_PATH` set:

```bash
export UCODE_REQUIRE_PATH="/usr/share/ucode/?.uc:/usr/local/crow/?.uc"
ucode /usr/local/crow/router.uc
```

Or via init script wrapper:

```bash
sh -c 'export UCODE_REQUIRE_PATH="/usr/share/ucode/?.uc:/usr/local/crow/?.uc" && exec ucode /usr/local/crow/router.uc'
```

---

## Historical 0.0.2 Experiment

Commit `78b7d36` converted all `.uc` files to `require()` instead of ES6
`import`:

**Before:**
```javascript
import * as meshtastic from "meshtastic_backend";
import * as meshcore from "meshcore_backend";
```

**After:**
```javascript
const meshtastic = require("meshtastic_backend");
const meshcore = require("meshcore_backend");
```

**Why:** At the time, AREDN's ucode compatibility looked like it required
CommonJS-style loading.

Commit `778433f` later restored `import`/`export` module flow and adjusted the
AREDN init path instead.

---

## Historical Verification on Hub5 (AREDN 4.26.1.0)

The temporary `require()` layout was tested with:

```bash
# Direct ucode test
export UCODE_REQUIRE_PATH="/usr/share/ucode/?.uc:/usr/local/crow/?.uc"
ucode -c 'let router = require("router"); print("✅ Router loaded");'
# Output: ✅ Router loaded
```

---

## Historical Deployment Checklist

- [ ] Install IPK package
- [ ] Create symlinks: `ln -sf /usr/local/crow/*.uc /usr/share/ucode/`
- [ ] Verify symlinks present: `ls /usr/share/ucode/ | grep -E 'meshtastic|meshcore|router'`
- [ ] Check service status: `/etc/init.d/crow status`
- [ ] Tail logs: `logread | tail -20`
- [ ] Look for channel discovery messages

---

## Troubleshooting Notes

### "Module not found" errors

**Cause:** Symlinks weren't created or are in wrong path  
**Fix:**
```bash
ls -la /usr/share/ucode/*.uc | grep crow
# Should show symlinks, not "No such file"
```

### Service still won't start

**Try manual test:**
```bash
export UCODE_REQUIRE_PATH="/usr/share/ucode/?.uc:/usr/local/crow/?.uc"
cd /usr/local/crow
ucode router.uc
# Check for errors - Ctrl+C after 5 sec
```

### "Exports may only appear at top level"

**Cause:** Module loader/runtime mismatch for the package installed on the node.
**Fix:** Rebuild from the current branch and confirm the init wrapper/module path
matches the current import/export layout.

---

## Technical Details

### Why the require() experiment worked on AREDN

- AREDN's ucode has built-in require() function
- Module path resolution looks in `/usr/share/ucode/` by default
- Environment variable `UCODE_REQUIRE_PATH` extends search path
- Symlinks in `/usr/share/ucode/` are discovered by require()

### Why import/export needed init wrapper care

- ES module syntax depends on the file being loaded through ucode's module flow.
- Direct entrypoint execution on AREDN can produce module loader/runtime errors.
- Current Crow source uses `import`/`export`; rebuild from the current branch and
  use the restored AREDN init/module path rather than converting source files
  back to `require()`.

---

## Future Improvements

1. **Track AREDN ucode/module behavior** as node firmware versions change
   - Newer versions may simplify direct ES module entrypoints
   - Keep package init behavior aligned with the source module layout

2. **Document module path in AREDN ucode changelog**
   - Help future developers understand limitations
   - Share findings with AREDN project

3. **Test on standard OpenWrt node** (reference)
   - Verify selector layer works on OpenWrt
   - Isolate AREDN-specific issues

---

## Files Modified

Commit `78b7d36` converted all 34 `.uc` files in `/home/bill/Crow/*.uc` from
`import` to `require()`:
- router.uc
- meshtastic_backend.uc, meshcore_backend.uc
- meshtastic.uc, meshcore.uc
- All supporting modules (aprs, channel, commands, etc.)

Historical commit: `78b7d36` - "fix: convert ES6 import to require() for AREDN ucode compatibility"
Current-flow restore: `778433f` - "fix(aredn): restore import/export module flow; remove exports from router entrypoint"

---

## References

- **AREDN Firmware:** Version 4.26.1.0 (tested on hub5)
- **Hub5 Node:** KJ6DZB-WSB-hub5, 10.245.94.33:2222
- **ucode Version:** /usr/bin/ucode (AREDN standard)
- **Related Commit:** 78b7d36

---

## Questions?

Refer to:
- `docs/TROUBLESHOOTING.md` - General troubleshooting
- `docs/SETUP_GETTING_STARTED.md` - Quick start guide
- GitHub Issues - For AREDN-specific problems
