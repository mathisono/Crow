// Identity and location discovery helpers for the new MeshCore TNC backend.
//
// The current multicast meshcore.uc learns MeshCore public keys, names and
// positions from ADVERT packets. This helper mirrors that behavior for the
// KISS/TNC path without changing the old backend.

import * as node from "node";
import * as nodedb from "nodedb";

const HW_MESHCORE = 253;

const ADV_TYPE_NONE = 0;
const ADV_TYPE_CHAT = 1;
const ADV_TYPE_REPEATER = 2;
const ADV_TYPE_ROOM = 3;
const ADV_TYPE_SENSOR = 4;

function roleFromAdvertType(t)
{
    switch (t) {
        case ADV_TYPE_CHAT:
            return node.ROLE_COMPANION;
        case ADV_TYPE_REPEATER:
            return node.ROLE_REPEATER;
        case ADV_TYPE_ROOM:
            return node.ROLE_ROOM;
        case ADV_TYPE_SENSOR:
            return node.ROLE_SENSOR;
        case ADV_TYPE_NONE:
        default:
            return null;
    }
}

export function extractCallsign(text)
{
    if (!text) {
        return null;
    }
    const m = match(uc(text), /([A-Z]{1,2}[0-9][A-Z]{1,3})/);
    return m ? m[1] : null;
};

export function advertToNodeinfo(advert)
{
    const role = roleFromAdvertType(advert.role_type);
    const longname = advert.name ?? "";
    const callsign = extractCallsign(longname);
    const nodeinfo = {
        hw_model: HW_MESHCORE,
        platform: "meshcore",
        mc_public_key: advert.public_key,
        long_name: longname,
        short_name: callsign ?? substr(longname, 0, 4),
        is_unmessagable: advert.role_type !== ADV_TYPE_CHAT
    };
    if (role !== null) {
        nodeinfo.role = role;
    }
    if (callsign) {
        nodeinfo.callsign = callsign;
    }
    return nodeinfo;
};

export function rememberAdvert(parsed)
{
    if (!parsed?.advert?.ok) {
        return null;
    }

    const advert = parsed.advert.advert;
    const n = nodedb.getNodeByMeshcorePublickey(advert.public_key);
    nodedb.updateNodeinfo(n.id, advertToNodeinfo(advert));
    if (advert.position) {
        nodedb.updatePosition(n.id, advert.position);
    }

    return {
        id: n.id,
        public_key: advert.public_key,
        name: advert.name,
        callsign: extractCallsign(advert.name),
        position: advert.position
    };
};

export function enrichMessageIdentity(msg)
{
    if (!msg) {
        return null;
    }
    const n = nodedb.getNode(msg.from, false);
    const info = n?.nodeinfo;
    if (info) {
        msg.meshcore_public_key = info.mc_public_key;
        msg.meshcore_long_name = info.long_name;
        msg.originating_callsign = info.callsign ?? extractCallsign(info.long_name) ?? msg.originating_callsign;
    }
    return msg;
};

export function makeLocalAdvert()
{
    const info = node.getInfo();
    return {
        public_key: info.mc_public_key ?? info.public_key,
        name: info.long_name ?? info.callsign ?? "Crow",
        role_type: ADV_TYPE_CHAT,
        position: info.position ?? { latitude_i: 0, longitude_i: 0 }
    };
};
