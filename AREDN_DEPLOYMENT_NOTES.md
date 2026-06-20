# AREDN Deployment Notes - Module Resolution Fix

**Date:** 2026-06-20  
**Issue:** Module resolution on AREDN's ucode interpreter  
**Status:** ✅ SOLVED - Documented workaround & permanent fix implemented

---

## Problem Summary

AREDN's ucode interpreter has limitations with ES6 `import` statements and module path resolution. Direct deployments to `/usr/local/crow/` result in:

```
Syntax error: Exports may only appear at top level of a module
In router.uc, line 18, byte 1:
```

This occurs because the ucode module loader can't resolve custom import paths outside `/usr/share/ucode/`.

---

## Solution 1: Symlink + Require() (Recommended for Production)

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

### Step 3: Router will auto-load with require()

The package includes source code converted from ES6 `import` to `require()` statements, which work with AREDN's ucode when modules are in `/usr/share/ucode/`.

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

## What Changed in 0.0.2

All `.uc` files now use `require()` instead of ES6 `import`:

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

**Why:** AREDN's ucode doesn't support ES6 module syntax, only require().

---

## Verification on Hub5 (AREDN 4.26.1.0)

✅ **Tested & Verified:**

```bash
# Direct ucode test
export UCODE_REQUIRE_PATH="/usr/share/ucode/?.uc:/usr/local/crow/?.uc"
ucode -c 'let router = require("router"); print("✅ Router loaded");'
# Output: ✅ Router loaded
```

---

## Deployment Checklist

- [ ] Install IPK package
- [ ] Create symlinks: `ln -sf /usr/local/crow/*.uc /usr/share/ucode/`
- [ ] Verify symlinks present: `ls /usr/share/ucode/ | grep -E 'meshtastic|meshcore|router'`
- [ ] Check service status: `/etc/init.d/crow status`
- [ ] Tail logs: `logread | tail -20`
- [ ] Look for channel discovery messages

---

## Troubleshooting

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

**Cause:** Using old package (pre-require() conversion)  
**Fix:** Rebuild package from commit `78b7d36` or later

---

## Technical Details

### Why require() works on AREDN

- AREDN's ucode has built-in require() function
- Module path resolution looks in `/usr/share/ucode/` by default
- Environment variable `UCODE_REQUIRE_PATH` extends search path
- Symlinks in `/usr/share/ucode/` are discovered by require()

### Why ES6 import doesn't work on AREDN

- ES6 module syntax is newer ucode feature
- AREDN's ucode version is from 2023
- Standard OpenWrt supports ES6 import; AREDN's doesn't
- Fix: Downgrade to CommonJS require() for compatibility

---

## Future Improvements

1. **Consider AREDN ucode version upgrade** when available
   - Newer versions may support ES6 import
   - Would simplify cross-platform code

2. **Document module path in AREDN ucode changelog**
   - Help future developers understand limitations
   - Share findings with AREDN project

3. **Test on standard OpenWrt node** (reference)
   - Verify selector layer works on OpenWrt
   - Isolate AREDN-specific issues

---

## Files Modified

All 34 `.uc` files in `/home/bill/Crow/*.uc` converted from `import` to `require()`:
- router.uc
- meshtastic_backend.uc, meshcore_backend.uc
- meshtastic.uc, meshcore.uc
- All supporting modules (aprs, channel, commands, etc.)

Commit: `78b7d36` - "fix: convert ES6 import to require() for AREDN ucode compatibility"

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
