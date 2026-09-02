import * as struct from "struct";
import * as timers from "timers";
import * as node from "node";
import * as utils from "utils";

const SAVE_INTERVAL = 31 * 60; // 31 minutes
const KEEP_WINDOW = 7 * 24 * 60 * 60; // 7 days
const MAX_TRANSIENT_MESHCORE = 16;
const TRANSIENT_MESHCORE_TTL = 60 * 60;

// Keep standalone module tests safe before the platform lifecycle calls setup().
let nodedb = {};
let transientMeshcore = {};
let transientMeshcoreOrder = [];

function isMeshcoreContact(n)
{
    return n?.nodeinfo?.platform === "meshcore" ||
        n?.nodeinfo?.platform === "meshcore-direct";
}

function pruneMeshcoreContacts()
{
    let removed = 0;
    for (let id in nodedb) {
        if (isMeshcoreContact(nodedb[id]) && !nodedb[id].favorite) {
            delete nodedb[id];
            removed++;
        }
    }
    if (removed > 0) {
        DEBUG0("nodedb: removed %d non-favorite MeshCore contacts\n", removed);
        platform.store("nodedb", nodedb);
    }
}

function pruneTransientMeshcore()
{
    const cutoff = time() - TRANSIENT_MESHCORE_TTL;
    for (let id in transientMeshcore) {
        if ((transientMeshcore[id].lastseen ?? 0) < cutoff) {
            delete transientMeshcore[id];
            for (let i = 0; i < length(transientMeshcoreOrder); i++) {
                if (transientMeshcoreOrder[i] === id) {
                    splice(transientMeshcoreOrder, i, 1);
                    break;
                }
            }
        }
    }
}

export function setup(config)
{
    nodedb = platform.load("nodedb") ?? {};
    transientMeshcore = {};
    transientMeshcoreOrder = [];
    // Crow retains direct/group text, not the MeshCore contact directory.
    // Purge old records at boot so the policy takes effect immediately.
    pruneMeshcoreContacts();
    // The following can be removed after people have updated
    for (let k in nodedb) {
        const n = nodedb[k];
        n.sortkey = n.lastseen + (n.nodeinfo?.platform === "native" ? 10000000000 : 0);
    }
    timers.setInterval("nodedb", SAVE_INTERVAL);
};

function saveDB()
{
    pruneTransientMeshcore();
    const window = time() - KEEP_WINDOW;
    for (let id in nodedb) {
        const n = nodedb[id];
        if ((isMeshcoreContact(n) || n.lastseen < window) && !n.favorite) {
            delete nodedb[id];
        }
    }
    platform.store("nodedb", nodedb);
}

export function shutdown()
{
    saveDB();
};

export function getNode(id, create)
{
    // The node module has no identity until platform setup() runs.  Keep
    // standalone module tests and early boot callers from dereferencing it.
    let selfId = null;
    try {
        selfId = node.id();
    } catch (_) {}
    if (selfId !== null && id == selfId) {
        return {
            me: true,
            id: id,
            nodeinfo: node.getInfo()
        };
    }
    return nodedb[id] ?? transientMeshcore[`${id}`] ?? (create === false ? null : { id: id });
};

function saveNode(n)
{
    if (n.meshcore_transient) {
        const key = `${n.id}`;
        if (!transientMeshcore[key]) {
            push(transientMeshcoreOrder, key);
        }
        n.lastseen = time();
        transientMeshcore[key] = n;
        while (length(transientMeshcoreOrder) > MAX_TRANSIENT_MESHCORE) {
            delete transientMeshcore[shift(transientMeshcoreOrder)];
        }
        return;
    }
    if (!n.me) {
        nodedb[n.id] = n;
        n.lastseen = time();
        n.sortkey = time() + (n.nodeinfo?.platform === "native" ? 10000000000 : 0);
        global.event?.notify?.({ cmd: "node", id: n.id }, `node ${n.id}`);
    }
}

export function createNode(id)
{
    if (!nodedb[id]) {
        saveNode(getNode(id));
    }
    return nodedb[id];
};

export function getNodeByMeshcoreLongname(longname)
{
    for (let k in nodedb) {
        const info = nodedb[k].nodeinfo;
        if (info && info.long_name === longname && info.platform === "meshcore") {
            return nodedb[k];
        }
    }
    for (let k in transientMeshcore) {
        const info = transientMeshcore[k].nodeinfo;
        if (info && info.long_name === longname && info.platform === "meshcore") {
            return transientMeshcore[k];
        }
    }
    return null;
};

export function getNodeByMeshcorePublickey(public_key, create)
{
    for (let k in nodedb) {
        if (nodedb[k].nodeinfo?.mc_public_key === public_key) {
            return nodedb[k];
        }
    }
    for (let k in transientMeshcore) {
        if (transientMeshcore[k].nodeinfo?.mc_public_key === public_key) {
            return transientMeshcore[k];
        }
    }
    if (create === false) {
        return null;
    }
    const id = struct.unpack(">I", public_key)[0];
    const transient = {
        id: id,
        meshcore_transient: true,
        nodeinfo: {
            platform: "meshcore",
            mc_public_key: public_key,
            is_unmessagable: false
        }
    };
    saveNode(transient);
    return transient;
};

export function getNodesByPublickeyHash(publicKeyHash, wantNative)
{
    const nodes = [];
    for (let k in nodedb) {
        const n = nodedb[k];
        if (n.nodeinfo?.mc_public_key !== null && ord(n.nodeinfo.mc_public_key) === publicKeyHash) {
            const isNative = n.nodeinfo.platform === "native";
            if ((wantNative && isNative) || (!wantNative && !isNative)) {
                push(nodes, n);
            }
        }
    }
    for (let k in transientMeshcore) {
        const n = transientMeshcore[k];
        if (!wantNative && n.nodeinfo?.mc_public_key !== null &&
            ord(n.nodeinfo.mc_public_key) === publicKeyHash) {
            push(nodes, n);
        }
    }
    return nodes;
};

export function updateNode(n)
{
    if (n) {
        saveNode(n);
    }
};

export function updateNodeinfo(id, nodeinfo)
{
    const n = getNode(id);
    if (!n.me) {
        delete n.nodeinforequested;
        if (!n.nodeinfo) {
            n.nodeinfo = nodeinfo;
        }
        else {
            const cnodeinfo = n.nodeinfo;
            for (let k in nodeinfo) {
                cnodeinfo[k] = nodeinfo[k];
            }
        }
        n.nodeinfo.long_name = utils.utf8validCopy(n.nodeinfo.long_name ?? "");
        n.nodeinfo.short_name = utils.utf8validCopy(n.nodeinfo.short_name ?? "");
        saveNode(n);
    }
};

export function updatePosition(id, position)
{
    const n = getNode(id);
    if (!n.position) {
        n.position = position;
    }
    else {
        const cposition = n.position;
        for (let k in position) {
            cposition[k] = position[k];
        }
    }
    saveNode(n);
};

export function updateDeviceMetrics(id, metrics)
{
    const n = getNode(id);
    const telemetry = n.telemetry ?? (n.telemetry = {});
    telemetry.device_metrics = metrics;  
    saveNode(n);
};

export function updateEnvironmentMetrics(id, metrics)
{
    const n = getNode(id);
    const telemetry = n.telemetry ?? (n.telemetry = {});
    telemetry.environment_metrics = metrics;  
    saveNode(n);
};

export function updateAirQualityMetrics(id, metrics)
{
    const n = getNode(id);
    const telemetry = n.telemetry ?? (n.telemetry = {});
    telemetry.airquality_metrics = metrics;  
    saveNode(n);
};

export function updatePath(id, path)
{
    const n = getNode(id);
    n.path = path;
    saveNode(n);
};

export function getNodes(favorite)
{
    favorite = !favorite;
    const me = node.id();
    return filter(values(nodedb), n => n.id != me && !n.favorite === favorite);
};

export function namekey(id)
{
    return `DirectMessages ${id}`
};

export function tick()
{
    if (timers.tick("nodedb")) {
        saveDB();
    }
};

export function process(msg)
{
    if (msg.hop_start >= 0 && msg.hop_start >= msg.hop_limit) {
        const n = getNode(msg.from);
        n.hops = msg.hop_start - msg.hop_limit;
        saveNode(n);
    }
};
