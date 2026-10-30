// Shared JavaScript/ucode behavioral fixture. All paths and devices are inert.
let files, modes, fault, mounted, candidates, usb, healthy, mountResult, bootSaved;
let removed, mounts, pruned, writes, passed = 0;
const etcBase = "/etc/crow.conf";
const etcOverride = "/etc/crow.conf.override";
const localBase = "/usr/local/crow/crow.conf";
const localOverride = "/usr/local/crow/crow.conf.override";
const initialBase = {
    storage: { mode: "internal", image_quota_mb: 64, min_free_mb: 16, keep: "base" },
    channels: [{ namekey: "AREDN fixture" }],
    aprs: { enabled: false }
};
const initialOverride = {
    storage: { min_free_mb: 8, keep: null, custom: { preserved: true } },
    channels: [{ namekey: "AREDN fixture", label: "Operator café" }],
    aprs: { enabled: true }
};
function check(condition, name) { if (!condition) die(`FAIL: ${name}\n`); }
const fs = {
    dirname: function() { return "/usr/local/crow"; },
    access: function(path) { return files[path] != null; },
    readfile: function(path) { return files[path] ?? null; },
    // Kept for the pre-fix negative control, whose writer directly truncates.
    writefile: function(path, data) { files[path] = data; writes++; return length(data); },
    open: function(path, mode, permission) {
        if (fault === "open" || files[path] != null) return null;
        check(mode === "wx" && permission === 0o600, "override temp must be exclusive and private");
        modes[path] = permission;
        files[path] = "";
        return {
            write: function(data) {
                files[path] = fault === "short" ? "{" : data;
                return length(files[path]);
            },
            flush: function() { return fault === "flush" ? null : true; },
            close: function() { return true; }
        };
    },
    rename: function(from, to) {
        if (fault === "rename") return null;
        files[to] = files[from]; modes[to] = modes[from];
        delete files[from]; delete modes[from]; writes++;
        return true;
    },
    unlink: function(path) { delete files[path]; delete modes[path]; return true; }
};
const channel = { getAllLocalChannels: function() { return [{ namekey: "AREDN fixture", label: "UI saved" }]; } };
function hasUsbPort() { return usb; }
function setInternalStorage() { storageState = "internal"; storageReason = null; }
function setDegradedStorage(reason) { storageState = "degraded"; storageReason = reason; }
function activateMountedUsb() {
    if (!mounted || !healthy) return false;
    storageState = "usb"; storageReason = null; return true;
}
function currentMountDevice() { return mounted; }
function deviceIsSafeUsb(device) { return device === "/dev/sda1" || device === "/dev/sdb1"; }
function blockInfo(device) { return { LABEL: device === "/dev/sda1" ? "CROWDATA" : "SECOND", TYPE: "ext4", UUID: "fixture" }; }
function persistStorageMount() { return bootSaved; }
function removeStoragePersistence() { removed++; }
function storageScan() { return candidates; }
function mkdirp() {}
function migrateDataToUsb() {}
function imageQuotaPrune() { pruned++; }
function readTrim() { return "ready"; }
function safeShellArg(value) { return value; }
function system(command) {
    if (index(command, "/bin/mount ") === 0) {
        mounts++;
        if (mountResult === 0) mounted = "/dev/sda1";
        return mountResult;
    }
    return 0;
}
// PRODUCTION_FUNCTIONS
function equal(actual, expected, name) { check(jsonEq(actual, expected), name); }
function reset() {
    files = {}; modes = {}; fault = null; mounted = "/dev/sda1";
    usb = true; healthy = true; mountResult = 0; bootSaved = true;
    candidates = [{ device: "/dev/sda1", label: "CROWDATA", filesystem: "ext4" }];
    removed = 0; mounts = 0; pruned = 0; writes = 0;
    files[etcBase] = sprintf("%J", initialBase);
    files[etcOverride] = sprintf("%J", initialOverride);
    reloadConfiguration();
}
function test(name, run) {
    reset(); run(); passed++; print("ok - ", name, "\n");
}
function checkSavedUsb() {
    const saved = json(files[etcOverride]);
    check(saved.storage.mode === "usb", "activation must persist Crow's USB mode");
    check(saved.storage.device === mounted, "activation must persist the actual device");
    check(saved.storage.mountpoint === "/mnt/crow", "activation must persist its mountpoint");
    check(modes[etcOverride] === 0o600, "saved override must remain private");
    reloadConfiguration();
    check(storageMode === "usb" && storageState === "usb", "USB must survive a fresh config reload");
}

test("already-mounted assimilation persists mode/device and survives restart", function() {
    const result = storageAssimilate();
    check(result.ok, "assimilation succeeds");
    checkSavedUsb();
    check(result.persisted, "assimilation must confirm persistence");
    check(mounts === 0, "already-mounted storage must not be remounted");
});
test("new mount persists mode/device and survives restart", function() {
    mounted = null;
    check(storageAssimilate().ok, "new-drive assimilation succeeds");
    check(mounts === 1, "new drive mounted once");
    checkSavedUsb();
});
test("USB enable persists the same settings as assimilation", function() {
    check(storageMount().ok, "USB enable succeeds");
    checkSavedUsb();
});
test("storage changes preserve unrelated settings and null tombstones", function() {
    const oldBase = files[etcBase];
    check(storageMount().ok, "mount succeeds");
    const saved = json(files[etcOverride]);
    equal(saved.channels, initialOverride.channels, "channel labels preserved");
    equal(saved.aprs, initialOverride.aprs, "APRS settings preserved");
    equal(saved.storage.custom, initialOverride.storage.custom, "unknown storage fields preserved");
    check(saved.storage.keep === null && saved.storage.min_free_mb === 8, "storage overrides preserved");
    check(files[etcBase] === oldBase, "base file unchanged");
    reloadConfiguration();
    check(config.storage.keep == null && storageMinFree === 8 * 1024 * 1024, "restart preserves overrides");
});
test("matching base USB mode removes a stale internal override", function() {
    const base = clone(initialBase); base.storage.mode = "usb";
    const saved = clone(initialOverride); saved.storage.mode = "internal";
    files[etcBase] = sprintf("%J", base); files[etcOverride] = sprintf("%J", saved);
    reloadConfiguration();
    check(storageMode === "internal", "old override wins before activation");
    check(storageMount().ok, "activation succeeds");
    check(json(files[etcOverride]).storage.mode == null, "redundant mode override removed");
    reloadConfiguration(); check(storageMode === "usb", "base USB mode restored");
});
test("a whole-storage tombstone keeps deleted base settings deleted", function() {
    const saved = clone(initialOverride); saved.storage = null;
    files[etcOverride] = sprintf("%J", saved); reloadConfiguration();
    check(config.storage == null, "storage initially deleted");
    check(storageMount().ok, "activation succeeds");
    reloadConfiguration();
    check(storageMode === "usb" && config.storage.keep == null, "deleted base fields do not reappear");
    check(storageImageQuota === DEFAULT_IMAGE_QUOTA && storageMinFree === DEFAULT_MIN_FREE, "default quotas remain effective");
});
test("disable persists internal mode even while the drive stays mounted", function() {
    check(storageMount().ok, "enable succeeds");
    check(storageDisable().ok, "disable succeeds");
    check(removed === 1, "boot mount persistence removed");
    reloadConfiguration();
    check(mounted !== null && storageMode === "internal" && storageState === "internal", "disable survives reload");
});
test("disable overrides a base-file USB default", function() {
    const base = clone(initialBase); base.storage.mode = "usb";
    files[etcBase] = sprintf("%J", base); reloadConfiguration();
    check(storageDisable().ok, "disable succeeds");
    reloadConfiguration(); check(storageMode === "internal", "saved disable overrides base USB");
});
test("image quota persists without changing storage mode", function() {
    check(setImageQuota(96).ok, "quota update succeeds");
    reloadConfiguration();
    check(storageImageQuota === 96 * 1024 * 1024 && storageMode === "internal", "quota survives reload");
});
test("package-local configurations save to the matching local override", function() {
    files[localBase] = files[etcBase]; files[localOverride] = files[etcOverride];
    delete files[etcBase]; delete files[etcOverride]; reloadConfiguration();
    check(storageMount().ok, "local config activation succeeds");
    check(files[etcOverride] == null && json(files[localOverride]).storage.mode === "usb", "correct override path used");
    reloadConfiguration(); check(storageMode === "usb", "local override survives reload");
});
test("later channel UI saves preserve newly saved storage settings", function() {
    check(storageMount().ok, "mount succeeds"); config.update("channels");
    reloadConfiguration();
    check(storageMode === "usb" && config.channels[0].label === "UI saved", "both changes survive reload");
});
test("failed mount never commits USB mode", function() {
    const saved = files[etcOverride]; mounted = null; mountResult = 1;
    check(!storageMount().ok, "mount failure reported");
    check(files[etcOverride] === saved, "failed activation does not alter configuration");
});
test("failed health check never commits USB mode", function() {
    const saved = files[etcOverride]; healthy = false;
    check(!storageMount().ok, "health failure reported");
    check(files[etcOverride] === saved, "unhealthy activation not persisted");
});
test("missing USB hardware does not write configuration", function() {
    const saved = files[etcOverride]; usb = false;
    check(!storageAssimilate().ok && files[etcOverride] === saved, "no-USB failure leaves settings intact");
});
test("ambiguous USB drives do not change saved settings", function() {
    const saved = files[etcOverride]; mounted = null;
    candidates = [{ device: "/dev/sda1" }, { device: "/dev/sdb1" }];
    check(!storageAssimilate().ok && files[etcOverride] === saved, "ambiguous activation refused");
});
test("unsafe requested device is not persisted", function() {
    const saved = files[etcOverride]; mounted = null;
    check(!storageMount("/dev/root").ok && files[etcOverride] === saved, "unsafe activation refused");
});
for (let failure in { open: true, short: true, flush: true, rename: true }) {
    test(`configuration ${failure} failure preserves the old override and reports partial activation`, function() {
        const saved = files[etcOverride]; const before = clone(config.storage); fault = failure;
        const result = storageMount();
        check(!result.ok && result.active && result.persisted === false, "active but unsaved must not report success");
        check(files[etcOverride] === saved, "last good override is byte-identical");
        equal(config.storage, before, "failed save must not change in-memory configuration");
        check(length(keys(files)) === 2, "failed writes leave no temporary files");
        fault = null; check(storageMount().ok, "retry can recover"); checkSavedUsb();
    });
}
test("disable save failure preserves the active mode and boot mount", function() {
    check(storageMount().ok, "enable succeeds");
    const saved = files[etcOverride]; fault = "rename";
    check(!storageDisable().ok, "disable save error reported");
    check(storageMode === "usb" && storageState === "usb" && removed === 0, "failed disable leaves runtime intact");
    check(files[etcOverride] === saved, "saved USB mode preserved");
});
test("quota save failure keeps the old quota and does not prune", function() {
    const before = storageImageQuota; fault = "flush";
    check(!setImageQuota(1).ok, "quota save error reported");
    check(storageImageQuota === before && pruned === 0, "failed quota change must not delete images");
});
test("boot-mount persistence failure is not reported as durable activation", function() {
    const saved = files[etcOverride]; bootSaved = false;
    const result = storageMount();
    check(!result.ok && result.active && result.persisted === false, "boot persistence failure reported");
    check(files[etcOverride] === saved, "partial activation does not commit Crow mode");
});
test("missing configuration writer cannot report saved activation", function() {
    config.update = null;
    const result = storageMount();
    check(!result.ok && result.persisted === false, "missing writer reported");
});
test("already-mounted activation records the actual device rather than the scan candidate", function() {
    candidates = [{ device: "/dev/sdb1", label: "SECOND", filesystem: "ext4" }];
    const result = storageAssimilate();
    check(result.ok && result.device === "/dev/sda1" && result.label === "CROWDATA", "actual active identity reported");
    checkSavedUsb();
});
test("startup never writes settings and a temporarily missing drive retains USB intent", function() {
    check(storageMount().ok, "enable succeeds");
    const count = writes; const saved = files[etcOverride]; mounted = null;
    reloadConfiguration();
    check(storageMode === "usb" && storageState === "degraded", "missing USB degrades without forgetting selection");
    check(writes === count && files[etcOverride] === saved, "startup is read-only");
    mounted = "/dev/sda1"; reloadConfiguration();
    check(storageState === "usb" && writes === count, "device returns without another configuration write");
});
printf("%d storage persistence checks passed\n", passed);
