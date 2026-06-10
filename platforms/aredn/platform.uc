import * as fs from "fs";
import * as timers from "../../timers.uc";
import * as uci from "uci";
import * as services from "aredn.services";
import * as babel from "aredn.babel";
import * as node from "../../node.uc";
import * as channel from "../../channel.uc";

const CURL = "/usr/bin/curl";

const pubID = "KN6PLV.raven.v1.1";
const pubTopic = "KN6PLV.raven.v1";

const RESCAN_INTERVAL = 1 * 60; // 1 minute
const STORE_SORT_TIMEOUT = 10 * 60; // 10 minutes

const MAX_BINARY_MEM = 0.1; // 10% free ram for binary storage

const LOCATION_SOURCE_INTERNAL = 2;

const CROW_INTERNAL_ROOT = "/usr/local/crow";
const CROW_TMP_ROOT = "/tmp/apps/crow";
const CROW_USB_MOUNT = "/mnt/crow";
const CROW_USB_LABEL = "CROWDATA";
const DEFAULT_IMAGE_QUOTA = 64 * 1024 * 1024;
const DEFAULT_MIN_FREE = 16 * 1024 * 1024;

const ucdata = {};
let bynamekey = {};
let byid = {};
let stores = {};
let myid;
let meshipEnabled = false;
let meshtasticEnabled = false;
let meshcoreEnabled = false;
let meshipBridgeEnabled = false;
let storesEnabled = null;
let hasMeshIpForwarder = false;
let bridges = [];
const badges = {};
let pwatcher = null;
let watcher = null;
let maxBinarySize = 1 * 1024 * 1024;
let inShutdown = false;
let storeSort = 0;
let ramMessages = false;
let storageMode = "internal";
let storageState = "internal";
let storageReason = null;
let storageRoot = CROW_INTERNAL_ROOT;
let storageImageRoot = `${CROW_TMP_ROOT}/images`;
let storageMountpoint = CROW_USB_MOUNT;
let storageLabel = CROW_USB_LABEL;
let storageDevice = null;
let storageMinFree = DEFAULT_MIN_FREE;
let storageImageQuota = DEFAULT_IMAGE_QUOTA;

function mkdirp(p)
{
    const d = fs.dirname(p);
    if (d && !fs.access(d)) {
        mkdirp(d);
    }
    fs.mkdir(p);
}

function safeShellArg(s)
{
    return match(s, /^[A-Za-z0-9_@%+=:,./-]+$/) ? s : null;
}

function readTrim(p)
{
    try {
        return trim(fs.readfile(p));
    }
    catch (_) {
        return null;
    }
}

function currentMountDevice(mountpoint)
{
    const mounts = split(fs.readfile("/proc/mounts") ?? "", "\n");
    for (let i = 0; i < length(mounts); i++) {
        const parts = split(trim(mounts[i]), " ");
        if (length(parts) >= 2 && parts[1] === mountpoint) {
            return parts[0];
        }
    }
    return null;
}

function freeBytes(p)
{
    const arg = safeShellArg(p);
    if (!arg) {
        return null;
    }
    const f = fs.popen(`df -Pk ${arg} 2>/dev/null`);
    if (!f) {
        return null;
    }
    const out = f.read("all");
    f.close();
    const lines = split(trim(out ?? ""), "\n");
    if (length(lines) < 2) {
        return null;
    }
    const m = match(lines[length(lines) - 1], /^\S+\s+\d+\s+\d+\s+(\d+)\s+/);
    return m ? (m[1] + 0) * 1024 : null;
}

function setInternalStorage()
{
    storageState = "internal";
    storageReason = null;
    storageRoot = CROW_INTERNAL_ROOT;
    storageImageRoot = `${CROW_TMP_ROOT}/images`;
    mkdirp(`${CROW_INTERNAL_ROOT}/data`);
    mkdirp(`${CROW_INTERNAL_ROOT}/winlink/forms`);
    mkdirp(`${CROW_TMP_ROOT}/images`);
    if (ramMessages) {
        mkdirp(`${CROW_TMP_ROOT}/data`);
    }
}

function setDegradedStorage(reason)
{
    storageState = "degraded";
    storageReason = reason;
    storageRoot = CROW_INTERNAL_ROOT;
    storageImageRoot = `${CROW_TMP_ROOT}/images`;
    mkdirp(`${CROW_TMP_ROOT}/images`);
    if (ramMessages) {
        mkdirp(`${CROW_TMP_ROOT}/data`);
    }
}

function prepareStorageRoot(root)
{
    try {
        mkdirp(`${root}/data`);
        mkdirp(`${root}/winlink/forms`);
        mkdirp(`${root}/images`);
        const test = `${root}/.crow-write-test`;
        fs.writefile(test, "ok");
        fs.unlink(test);
        const free = freeBytes(root);
        if (free !== null && free < storageMinFree) {
            return `not enough free space on ${root}`;
        }
        return null;
    }
    catch (e) {
        return `storage root is not writable: ${e}`;
    }
}

function copyIfMissing(srcDir, dstDir)
{
    if (!fs.access(srcDir) || !fs.access(dstDir)) {
        return;
    }
    const entries = fs.lsdir(srcDir);
    for (let i = 0; i < length(entries); i++) {
        const src = `${srcDir}/${entries[i]}`;
        const dst = `${dstDir}/${entries[i]}`;
        if (!fs.access(dst)) {
            const data = fs.readfile(src);
            if (data != null) {
                fs.writefile(dst, data);
            }
        }
    }
}

function migrateDataToUsb()
{
    if (storageState !== "usb" || !storageMountpoint) {
        return;
    }
    // Copy message data from internal to USB if USB dirs are empty
    copyIfMissing(`${CROW_INTERNAL_ROOT}/data`, `${storageMountpoint}/data`);
    copyIfMissing(`${CROW_TMP_ROOT}/images`, `${storageMountpoint}/images`);
    // Winlink forms subdirectories need recursive handling
    const formSrc = `${CROW_INTERNAL_ROOT}/winlink/forms`;
    const formDst = `${storageMountpoint}/winlink/forms`;
    if (fs.access(formSrc) && fs.access(formDst)) {
        const subdirs = fs.lsdir(formSrc);
        for (let i = 0; i < length(subdirs); i++) {
            const s = `${formSrc}/${subdirs[i]}`;
            const d = `${formDst}/${subdirs[i]}`;
            const st = fs.lstat(s);
            if (st?.type === "directory") {
                mkdirp(d);
                copyIfMissing(s, d);
            }
        }
    }
}

function activateMountedUsb()
{
    const mounted = currentMountDevice(storageMountpoint);
    if (!mounted) {
        return false;
    }
    const reason = prepareStorageRoot(storageMountpoint);
    if (reason) {
        setDegradedStorage(reason);
        return false;
    }
    storageState = "usb";
    storageReason = null;
    storageRoot = storageMountpoint;
    storageImageRoot = `${storageMountpoint}/images`;
    migrateDataToUsb();
    return true;
}

function removableBlockForDevice(device)
{
    const m = match(device ?? "", /^\/dev\/([a-z]+)\d*$/);
    if (!m) {
        return null;
    }
    const block = m[1];
    return readTrim(`/sys/block/${block}/removable`) === "1" ? block : null;
}

function deviceIsSafeUsb(device)
{
    if (!match(device ?? "", /^\/dev\/[A-Za-z0-9._-]+$/)) {
        return false;
    }
    return removableBlockForDevice(device) !== null;
}

function partitionForBlock(block)
{
    try {
        const entries = fs.lsdir(`/sys/block/${block}`);
        for (let i = 0; i < length(entries); i++) {
            if (index(entries[i], block) === 0 && length(entries[i]) > length(block) && match(entries[i], /^[a-z]+[0-9]+$/)) {
                return `/dev/${entries[i]}`;
            }
        }
    }
    catch (_) {
    }
    return `/dev/${block}`;
}

function imageQuotaPrune()
{
    if (!fs.access(storageImageRoot)) {
        return;
    }
    let size = 0;
    const files = [];
    for (let f in fs.lsdir(storageImageRoot)) {
        const p = `${storageImageRoot}/${f}`;
        const st = fs.lstat(p);
        if (st?.type === "file") {
            size += st.size;
            push(files, { path: p, size: st.size, mtime: st.mtime });
        }
    }
    sort(files, (a, b) => a.mtime - b.mtime);
    for (let i = 0; size > storageImageQuota && i < length(files); i++) {
        fs.unlink(files[i].path);
        size -= files[i].size;
    }
}

function setupStorage(config)
{
    const sc = config.storage ?? {};
    storageMode = sc.mode ?? "internal";
    storageMountpoint = sc.mountpoint ?? CROW_USB_MOUNT;
    storageLabel = sc.label ?? CROW_USB_LABEL;
    storageDevice = sc.device ?? null;
    storageImageQuota = sc.image_quota_mb ? (sc.image_quota_mb + 0) * 1024 * 1024 : DEFAULT_IMAGE_QUOTA;
    storageMinFree = sc.min_free_mb ? (sc.min_free_mb + 0) * 1024 * 1024 : DEFAULT_MIN_FREE;

    setInternalStorage();
    if (storageMode === "usb" && !activateMountedUsb()) {
        setDegradedStorage(`USB storage is not mounted at ${storageMountpoint}`);
    }
}

/* export */ function storageStatus()
{
    if (storageMode === "usb" && storageState === "usb") {
        activateMountedUsb();
    }
    return {
        state: storageState,
        mode: storageMode,
        root: storageRoot,
        image_root: storageImageRoot,
        mountpoint: storageMountpoint,
        device: currentMountDevice(storageMountpoint) ?? storageDevice,
        reason: storageReason,
        image_quota_mb: storageImageQuota / (1024 * 1024),
        min_free_mb: storageMinFree / (1024 * 1024)
    };
}

/* export */ function storageScan()
{
    const candidates = [];
    let mounted = null;
    try {
        const blocks = fs.lsdir("/sys/block");
        for (let i = 0; i < length(blocks); i++) {
            const b = blocks[i];
            if (!match(b, /^[A-Za-z0-9._-]+$/)) {
                continue;
            }
            if (readTrim(`/sys/block/${b}/removable`) !== "1") {
                continue;
            }
            const sectors = readTrim(`/sys/block/${b}/size`) + 0;
            const device = partitionForBlock(b);
            mounted = currentMountDevice(storageMountpoint) === device;
            push(candidates, {
                device: device,
                block: b,
                model: readTrim(`/sys/block/${b}/device/model`) ?? "removable storage",
                size_bytes: sectors * 512,
                mounted: mounted
            });
        }
    }
    catch (_) {
    }
    return candidates;
}

/* export */ function storageMount()
{
    storageMode = "usb";
    if (activateMountedUsb()) {
        return { ok: true, message: "USB storage active." };
    }

    let device = storageDevice;
    if (device && !deviceIsSafeUsb(device)) {
        setDegradedStorage(`Refusing unsafe storage device ${device}`);
        return { ok: false, message: storageReason };
    }

    if (!device) {
        const candidates = storageScan();
        if (!candidates || length(candidates) === 0) {
            setDegradedStorage("No removable USB storage candidates found.");
            return { ok: false, message: storageReason };
        }
        device = candidates[0].device;
    }

    if (!deviceIsSafeUsb(device)) {
        setDegradedStorage(`Refusing unsafe storage device ${device}`);
        return { ok: false, message: storageReason };
    }

    mkdirp(storageMountpoint);
    const devArg = safeShellArg(device);
    const mntArg = safeShellArg(storageMountpoint);
    if (!devArg || !mntArg) {
        setDegradedStorage("Storage device or mountpoint contains unsafe characters.");
        return { ok: false, message: storageReason };
    }

    if (system(`/bin/mount -o noatime ${devArg} ${mntArg} >/dev/null 2>&1`) !== 0 && !activateMountedUsb()) {
        setDegradedStorage(`Unable to mount ${device} at ${storageMountpoint}`);
        return { ok: false, message: storageReason };
    }

    if (!activateMountedUsb()) {
        return { ok: false, message: storageReason ?? "USB storage mounted but failed health checks." };
    }
    storageDevice = device;
    migrateDataToUsb();
    imageQuotaPrune();
    return { ok: true, message: "USB storage active." };
}

/* export */ function storageDisable()
{
    storageMode = "internal";
    setInternalStorage();
    return { ok: true, message: "Crow storage returned to internal node storage." };
}

/* export */ function storageImageQuota(mb)
{
    const quota = +mb;
    if (!(quota > 0 && quota <= 65536)) {
        return { ok: false, message: "Image quota must be between 1 and 65536 MB." };
    }
    storageImageQuota = quota * 1024 * 1024;
    imageQuotaPrune();
    return { ok: true, message: `Image quota set to ${quota} MB.` };
}

/* export */ function setup(config)
{
    if (config.messages?.ram) {
        ramMessages = true;
    }

    setupStorage(config);

    const c = uci.cursor();
    ucdata.latitude = c.get("aredn", "@location[0]", "lat");
    ucdata.longitude = c.get("aredn", "@location[0]", "lon");
    ucdata.gridsquare = c.get("aredn", "@location[0]", "gridsquare");
    ucdata.height = c.get("aredn", "@location[0]", "height");
    ucdata.hostname = c.get("system", "@system[0]", "hostname");
    ucdata.mapUrl = c.get("aredn", "@location[0]", "map");
    ucdata.isSupernode = c.get("aredn", "@supernode[0]", "enable") == "1";

    const cm = uci.cursor("/etc/config.mesh");
    ucdata.main_ip = cm.get("setup", "globals", "wifi_ip");
    ucdata.lan_ip = cm.get("setup", "globals", "dmz_lan_ip");

    const cu = uci.cursor("/etc/local/uci");
    ucdata.macaddress = map(split(cu.get("hsmmmesh", "settings", "wifimac"), ":"), v => hex(v));

    // Supernodes can *only* forward meship traffic. We disable every other kind of bridge
    // just in case they were enabled. Same for text storage as we dont want to store
    // text for every mesh in the supernode mesh. And make them unmessagable too.
    if (ucdata.isSupernode) {
        delete config.meshtastic;
        delete config.meshcore;
        delete config.textstore;
        delete config.messages;
    }

    if (config.arednmesh) {
        config.meship = config.arednmesh;
    }
    if (config.meship) {
        meshipEnabled = true;
        if (ucdata.isSupernode) {
            meshipBridgeEnabled = true;
            config.meship.bridge = true;
        }
        if (config.textstore) {
            if (config.textstore.stores) {
                storesEnabled = map(config.textstore.stores, s => s.namekey);
            }
            else {
                storesEnabled = [ "*" ];
            }
        }
    }

    if (config.meshtastic) {
        meshtasticEnabled = true;
    }
    if (config.meshcore) {
        meshcoreEnabled = true;
    }

    const freemem = 1024 * match(fs.readfile("/proc/meminfo"), /MemFree: +(\d+) kB/)[1];
    const binarymem = freemem * MAX_BINARY_MEM;
    if (binarymem > maxBinarySize) {
        maxBinarySize = binarymem;
    }

    if (services.watch) {
        pwatcher = services.watch("publish");
        // We need a proper file description which supports ioctl calls.
        watcher = fs.fdopen(pwatcher.fileno());
    }
    else {
        timers.setInterval("aredn", 0, RESCAN_INTERVAL);
    }
}

/* export */ function shutdown()
{
    inShutdown = true;
    services.unpublish(pubID);
    if (watcher) {
        services.unwatch(pwatcher);
        watcher.close();
    }
}

/* export */ function mergePlatformConfig(config)
{
    const location = config.location ?? (config.location = {});
    if (location.latitude === null) {
        location.latitude = ucdata.latitude;
    }
    if (location.longitude === null) {
        location.longitude = ucdata.longitude;
    }
    if (location.altitude === null) {
        location.altitude = ucdata.height;
    }
    if (location.gridsquare === null) {
        location.gridsquare = ucdata.gridsquare;
    }
    if (location.precision === null) {
        location.precision = 32;
    }
    if (location.source === null && fs.readfile("/tmp/timesync") === "gps") {
        location.source = LOCATION_SOURCE_INTERNAL;
    }

    if (config.meshtastic && config.meshtastic?.address === null) {
        config.meshtastic.address = ucdata.lan_ip;
    }
    if (config.meshcore && config.meshcore?.address === null) {
        config.meshcore.address = ucdata.lan_ip;
    }

    if (config.role === "client_mute" && (config.meshtastic || config.meshcore || ucdata.isSupernode) && config.meship) {
        config.role = "client";
    }

    if (!config.channels) {
        config.channels = [];
    }
    if (length(filter(config.channels, c => c.namekey === "AREDN og==")) === 0) {
        push(config.channels, { "namekey": "AREDN og==" });
    }

    if (config.long_name === null) {
        config.long_name = ucdata.hostname;
    }
    if (config.short_name === null) {
        config.short_name = substr(split(ucdata.hostname, "-", 2)[0], -4);
    }
    const callsign = split(config.long_name, "-")[0];
    if (callsign) {
        config.callsign = callsign;
    }

    if (config.macaddress === null) {
        config.macaddress = ucdata.macaddress;
    }
}

function path(name)
{
    if (storageMode === "usb" && storageState !== "usb") {
        activateMountedUsb();
    }
    // Image files are persistent on USB and temporary in internal/degraded mode.
    if (index(name, "img") === 0) {
        return `${storageImageRoot}/${name}`;
    }
    if (index(name, "winlink/") === 0) {
        return `${storageRoot}/${name}`;
    }
    if (ramMessages && index(name, "messages.") === 0) {
        return `${CROW_TMP_ROOT}/data/${replace(name, /\//g, "_")}.json`;
    }
    return `${storageRoot}/data/${replace(name, /\//g, "_")}.json`;
}

/* export */ function load(name)
{
    const p = path(name);
    try {
        return json(fs.readfile(p));
    }
    catch (_) {
        fs.unlink(p);
    }
    try {
        return json(fs.readfile(`${p}~`));
    }
    catch (_) {
        fs.unlink(`${p}~`);
    }
    return null;
}

/* export */ function loadbinary(name)
{
    const p = path(name);
    try {
        return fs.readfile(p);
    }
    catch (_) {
        fs.unlink(p);
    }
    try {
        return fs.readfile(`${p}~`);
    }
    catch (_) {
        fs.unlink(`${p}~`);
    }
    return null;
}

/* export */ function store(name, data)
{
    const p = path(name);
    // Keep a copy of the stored file until the new one is written
    if (fs.access(p)) {
        fs.unlink(`${p}~`);
        fs.rename(p, `${p}~`);
    }
    if (name === "nodedb" && !inShutdown) {
        // Special handling because this gets very big
        // and big flash writes block the app for too long
        const filename = "/tmp/crow.nodedb";
        const f = fs.open(filename, "w");
        f.write("{\n");
        for (let id in data) {
            f.write(`  "${id}": ${sprintf("%J", data[id])},\n`)
        }
        f.write("}\n");
        f.close();
        system(`(mv -f ${filename} ${p}; rm -f ${p}~) &`);
    }
    else {
        fs.writefile(p, sprintf("%.02J", data));
        fs.unlink(`${p}~`);
    }
}

/* export */ function storebinary(name, data)
{
    const p = path(name);
    // Reduce cached files to maxBinarySize, or persistent image files to image quota.
    const dirname = fs.dirname(p);
    let size = 0;
    const limit = index(name, "img") === 0 ? storageImageQuota : maxBinarySize;
    const dir = map(fs.lsdir(dirname), f => {
        const i = fs.stat(`${dirname}/${f}`);
        size += i.size;
        return { f: f, m: i.mtime, s: i.size };
    });
    sort(dir, (a, b) => a.m - b.m);
    for (let i = 0; size > limit && i < length(dir); i++) {
        size -= dir[i].s;
        fs.unlink(`${dirname}/${dir[i].f}`);
    }
    fs.writefile(p, data);
}

/* export */ function dirtree(name)
{
    function read(dir)
    {
        const r = {};
        const files = fs.lsdir(dir);
        for (let i = 0; i < length(files); i++) {
            const n = files[i];
            const dn = `${dir}/${n}`;
            r[n] = fs.lstat(dn)?.type === "directory" ? read(dn) : true;
        }
        return r;
    }
    return read(path(name));
}

/* export */ function fetch(url, timeout)
{
    const p = fs.popen(`${CURL} --max-time ${timeout} --silent --output - ${url}`);
    if (!p) {
        return null;
    }
    const all = p.read("all");
    p.close();
    return all;
}

/* export */ function getTargetsByIdAndNamekey(id, namekey, canforward)
{
    let targets = [];
    if (id === node.BROADCAST) {
        const services = bynamekey[namekey];
        if (services) {
            targets = slice(services);
        }
        let store = stores[namekey];
        if (store) {
            targets = [ ...targets, ...store ];
        }
        store = stores["*"];
        if (store) {
            targets = [ ...targets, ...store ];
        }
    }
    else {
        const target = byid[id];
        if (target) {
            return [ target ];
        }
    }
    if (canforward && length(bridges) > 0) {
        targets = [ ...targets, ...bridges ];
    }
    return uniq(targets);
}

/* export */ function getTargetById(id)
{
    return byid[id];
}

/*
 * Order stores so the closest ones are first.
 */
function orderStores()
{
    const allstores = {};
    for (let k in stores) {
        const s = stores[k];
        for (let i = 0; i < length(s); i++) {
            allstores[s[i].ip] = { store: s[i], metric: 9999999 };
        }
    }
    const routes = babel.getHostRoutes();
    for (let i = 0; i < length(routes); i++) {
        const r = routes[i];
        const s = allstores[r.ip];
        if (s) {
            s.metric = r.metric;
        }
    }
    for (let k in stores) {
        sort(stores[k], (a, b) => allstores[a.ip].metric - allstores[b.ip].metrics);
    }
    storeSort = time() + STORE_SORT_TIMEOUT;
}

/* export */ function getStoreByNamekey(namekey)
{
    if (time() > storeSort) {
        orderStores();
    }
    return (stores[namekey] ?? stores["*"] ?? [])[0];
}

/* export */ function publish(me, channels)
{
    if (!meshipEnabled) {
        return;
    }
    myid = me.id;
    const info = {
        id: myid,
        ip: ucdata.main_ip,
        private_key: me.private_key,
        channels: map(channels, c => c.namekey)
    };
    if (storesEnabled) {
        info.store = storesEnabled;
    }
    if (meshtasticEnabled || meshcoreEnabled || meshipBridgeEnabled) {
        info.bridge = [];
        if (meshtasticEnabled) {
            const mconf = {};
            for (let i = 0; i < length(channels); i++) {
                if (channel.isMeshtasticPreset(channels[i].namekey)) {
                    mconf.preset = split(channels[i].namekey, " ")[0];
                    break;
                }
            }
            push(info.bridge, { meshtastic: mconf });
        }
        if (meshcoreEnabled) {
            push(info.bridge, { meshcore: {} });
        }
        if (meshipBridgeEnabled) {
            push(info.bridge, { meship: {} });
        }
    }
    services.publish(pubID, pubTopic, info);
}

/* export */ function badge(key, count)
{
    if (!count) {
        delete badges[key];
    }
    else {
        badges[key] = count;
    }
    let total = 0;
    for (let k in badges) {
        total += badges[k];
    }
    fs.writefile(`${CROW_TMP_ROOT}/badge`, total == 0 ? "" : total > 999 ? "999+" : `${total}`);
}

/* export */ function auth(headers)
{
    for (let i = 0; i < length(headers); i++) {
        const kv = split(headers[i], ": ");
        if (lc(kv[0]) === "cookie") {
            const ca = split(kv[1], ";");
            for (let j = 0; j < length(ca); j++) {
                const cookie = trim(ca[j]);
                if (index(cookie, "authV1=") === 0) {
                    let key = null;
                    const f = fs.open("/etc/shadow");
                    if (f) {
                        for (let l = f.read("line"); length(l); l = f.read("line")) {
                            if (index(l, "root:") === 0) {
                                key = trim(l);
                                break;
                            }
                        }
                        f.close();
                    }
                    return (key == b64dec(substr(cookie, 7)) ? true : false);
                }
            }
            break;
        }
    }
    return false;
};

function refreshTargets()
{
    const published = services.published(pubTopic);
    byid = {};
    bynamekey = {};
    const meshtasticForwarders = [];
    const meshcoreForwarders = [];
    const meshipForwarders = [];
    stores = {};
    hasMeshIpForwarder = false;
    for (let i = 0; i < length(published); i++) {
        const service = published[i];
        if (service.id !== myid) {
            byid[service.id] = service;
            const nchannels = {};
            for (let j = 0; j < length(service.channels); j++) {
                const namekey = service.channels[j];
                if (!bynamekey[namekey]) {
                    bynamekey[namekey] = [];
                }
                push(bynamekey[namekey], service);
                nchannels[namekey] = true;
            }
            service.channels = nchannels;
            if (service.bridge && !meshipBridgeEnabled) {
                for (let j = 0; j < length(service.bridge); j++) {
                    const b = service.bridge[j];
                    if (!meshtasticEnabled && b.meshtastic) {
                        push(meshtasticForwarders, service);
                    }
                    if (!meshcoreEnabled && b.meshcore) {
                        push(meshcoreForwarders, service);
                    }
                    if (b.meship) {
                        hasMeshIpForwarder = true;
                        push(meshipForwarders, service);
                    }
                }
            }
            if (!ucdata.isSupernode && service.store) {
                for (let j = 0; j < length(service.store); j++) {
                    const key = service.store[j];
                    if (!stores[key]) {
                        stores[key] = [];
                    }
                    push(stores[key], service);
                }
            }
        }
    }
    channel.updateRemoteNameKeys(keys(bynamekey));
    bridges = uniq([ ...meshtasticForwarders, ...meshcoreForwarders, ...meshipForwarders ]);
    orderStores();
}

/* export */ function tick()
{
    if (timers.tick("aredn")) {
        refreshTargets();
    }
}

/* export */ function process(msg)
{
}

/* export */ function handle()
{
    return watcher;
}

/* export */ function handleChanges()
{
    const FIONREAD_TYPE = 0x54;
    const FIONREAD_NUM = 0x1B;

    const len = watcher.ioctl(fs.IOC_DIR_READ, FIONREAD_TYPE, FIONREAD_NUM, 4);
    if (len === null || len < 0) {
        services.unwatch(pwatcher);
        watcher.close();
        pwatcher = services.watch("publish");
        watcher = fs.fdopen(pwatcher.fileno());
    }
    else if (len > 0) {
        watcher.read(len);
    }

    refreshTargets();
}

/* export */ function getMap(lat, lon)
{
    return ucdata.mapUrl ? replace(replace(ucdata.mapUrl, "(lat)", lat), "(lon)", lon) : null;
}

/* export */ function canAcceptIPAddress(address)
{
    return hasMeshIpForwarder || system(`/sbin/ip route show table 20 | grep -q ${address}`) === 0;
}

return {
    setup,
    shutdown,
    mergePlatformConfig,
    load,
    loadbinary,
    store,
    storebinary,
    dirtree,
    fetch,
    getTargetsByIdAndNamekey,
    getTargetById,
    getStoreByNamekey,
    publish,
    badge,
    auth,
    tick,
    process,
    handle,
    handleChanges,
    getMap,
    canAcceptIPAddress,
    storageStatus,
    storageScan,
    storageMount,
    storageDisable,
    storageImageQuota
};
