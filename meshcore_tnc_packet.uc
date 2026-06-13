// MeshCore raw packet parser/builder for the new TNC backend.
//
// This intentionally does not import or modify the existing meshcore.uc
// multicast bridge backend.

import * as struct from "struct";
import * as crypto from "crypto.crypto";

export const ROUTE_TYPE_TRANSPORT_FLOOD = 0x00;
export const ROUTE_TYPE_FLOOD = 0x01;
export const ROUTE_TYPE_DIRECT = 0x02;
export const ROUTE_TYPE_TRANSPORT_DIRECT = 0x03;

export const PAYLOAD_TYPE_REQ = 0x00;
export const PAYLOAD_TYPE_RESPONSE = 0x01;
export const PAYLOAD_TYPE_TXT_MSG = 0x02;
export const PAYLOAD_TYPE_ACK = 0x03;
export const PAYLOAD_TYPE_ADVERT = 0x04;
export const PAYLOAD_TYPE_GRP_TXT = 0x05;
export const PAYLOAD_TYPE_GRP_DATA = 0x06;
export const PAYLOAD_TYPE_ANON_REQ = 0x07;
export const PAYLOAD_TYPE_PATH = 0x08;
export const PAYLOAD_TYPE_TRACE = 0x09;
export const PAYLOAD_TYPE_MULTIPART = 0x0a;
export const PAYLOAD_TYPE_CONTROL = 0x0b;
export const PAYLOAD_TYPE_RAW_CUSTOM = 0x0f;

export const PAYLOAD_VER_1 = 0x00;

export const TEXT_TYPE_PLAIN = 0x00;
export const TEXT_TYPE_CLI = 0x01;
export const TEXT_TYPE_SIGNED = 0x02;

export const ADV_TYPE_NONE = 0;
export const ADV_TYPE_CHAT = 1;
export const ADV_TYPE_REPEATER = 2;
export const ADV_TYPE_ROOM = 3;
export const ADV_TYPE_SENSOR = 4;

export const ADV_LATLON_MASK = 0x10;
export const ADV_FEAT1_MASK = 0x20;
export const ADV_FEAT2_MASK = 0x40;
export const ADV_NAME_MASK = 0x80;

const MAX_PACKET_PAYLOAD = 184;
const MAX_PATH_SIZE = 64;
const MAX_TEXT_MESSAGE_LENGTH = 150;

export function payloadTypeName(t)
{
    switch (t) {
        case PAYLOAD_TYPE_REQ: return "REQ";
        case PAYLOAD_TYPE_RESPONSE: return "RESPONSE";
        case PAYLOAD_TYPE_TXT_MSG: return "TXT_MSG";
        case PAYLOAD_TYPE_ACK: return "ACK";
        case PAYLOAD_TYPE_ADVERT: return "ADVERT";
        case PAYLOAD_TYPE_GRP_TXT: return "GRP_TXT";
        case PAYLOAD_TYPE_GRP_DATA: return "GRP_DATA";
        case PAYLOAD_TYPE_ANON_REQ: return "ANON_REQ";
        case PAYLOAD_TYPE_PATH: return "PATH";
        case PAYLOAD_TYPE_TRACE: return "TRACE";
        case PAYLOAD_TYPE_MULTIPART: return "MULTIPART";
        case PAYLOAD_TYPE_CONTROL: return "CONTROL";
        case PAYLOAD_TYPE_RAW_CUSTOM: return "RAW_CUSTOM";
        default: return sprintf("UNKNOWN_%02x", t);
    }
};

export function routeTypeName(t)
{
    switch (t) {
        case ROUTE_TYPE_TRANSPORT_FLOOD: return "TRANSPORT_FLOOD";
        case ROUTE_TYPE_FLOOD: return "FLOOD";
        case ROUTE_TYPE_DIRECT: return "DIRECT";
        case ROUTE_TYPE_TRANSPORT_DIRECT: return "TRANSPORT_DIRECT";
        default: return sprintf("UNKNOWN_%02x", t);
    }
};

export function hasTransportCodes(routeType)
{
    return routeType === ROUTE_TYPE_TRANSPORT_FLOOD || routeType === ROUTE_TYPE_TRANSPORT_DIRECT;
};

export function pathHashSize(pathinfo)
{
    const mode = pathinfo >> 6;
    if (mode === 3) {
        return 0;
    }
    return mode + 1;
};

export function pathHashCount(pathinfo)
{
    return pathinfo & 0x3f;
};

export function pathByteLength(pathinfo)
{
    const sz = pathHashSize(pathinfo);
    if (!sz) {
        return -1;
    }
    return sz * pathHashCount(pathinfo);
};

export function reversePath(pathinfo, path)
{
    const sz = pathHashSize(pathinfo);
    if (sz <= 1) {
        return reverse(path);
    }
    let out = "";
    for (let i = length(path) - sz; i >= 0; i -= sz) {
        out += substr(path, i, sz);
    }
    return out;
};

export function encodePathInfo(hashSize, hopCount)
{
    if (hashSize < 1 || hashSize > 3 || hopCount < 0 || hopCount > 63) {
        return null;
    }
    return ((hashSize - 1) << 6) | (hopCount & 0x3f);
};

export function makeHeader(payloadType, routeType, payloadVersion)
{
    payloadVersion = payloadVersion ?? PAYLOAD_VER_1;
    return ((payloadVersion & 0x03) << 6) | ((payloadType & 0x0f) << 2) | (routeType & 0x03);
};

function parseAdvert(payload)
{
    if (length(payload) < 101) {
        return { ok: false, error: "advert too short" };
    }

    let offset = 0;
    const publicKey = substr(payload, offset, 32);
    offset += 32;
    const timestamp = struct.unpack("<I", payload, offset)[0];
    offset += 4;
    const signature = substr(payload, offset, 64);
    offset += 64;
    const appdata = substr(payload, offset);

    const signed = publicKey + struct.pack("<I", timestamp) + appdata;
    if (!crypto.verify(publicKey, signed, signature)) {
        return { ok: false, error: "bad advert signature", public_key: publicKey };
    }

    let appOffset = 0;
    const flags = ord(appdata, appOffset);
    appOffset++;
    const advert = {
        public_key: publicKey,
        timestamp: timestamp,
        flags: flags,
        role_type: flags & 0x0f,
        appdata: appdata
    };

    if (flags & ADV_LATLON_MASK) {
        if (appOffset + 8 > length(appdata)) {
            return { ok: false, error: "partial advert location", public_key: publicKey };
        }
        const latlon = struct.unpack("<ii", appdata, appOffset);
        appOffset += 8;
        advert.position = {
            latitude_i: latlon[0] * 10,
            longitude_i: latlon[1] * 10
        };
    }
    if (flags & ADV_FEAT1_MASK) {
        appOffset += 2;
    }
    if (flags & ADV_FEAT2_MASK) {
        appOffset += 2;
    }
    if (flags & ADV_NAME_MASK) {
        advert.name = substr(appdata, appOffset);
    }

    return { ok: true, advert: advert };
}

function parseDirectEnvelope(payload)
{
    if (length(payload) < 4) {
        return { ok: false, error: "direct envelope too short" };
    }
    return {
        ok: true,
        destination_hash: ord(payload, 0),
        source_hash: ord(payload, 1),
        mac: struct.unpack("2B", payload, 2),
        ciphertext: substr(payload, 4)
    };
}

function parseGroupEnvelope(payload)
{
    if (length(payload) < 3) {
        return { ok: false, error: "group envelope too short" };
    }
    return {
        ok: true,
        channel_hash: ord(payload, 0),
        mac: struct.unpack("2B", payload, 1),
        ciphertext: substr(payload, 3)
    };
}

function parseAck(payload)
{
    if (length(payload) < 4) {
        return { ok: false, error: "ack too short" };
    }
    return {
        ok: true,
        checksum: struct.unpack("4B", payload, 0),
        checksum_raw: substr(payload, 0, 4)
    };
}

export function packetId(payloadType, pathinfo, payload)
{
    const h = crypto.sha256hash(chr(payloadType) + (payloadType === PAYLOAD_TYPE_TRACE ? struct.pack(">H", pathHashCount(pathinfo)) : "") + payload);
    return (h[0] << 24) | (h[1] << 16) + (h[2] << 8) + h[3];
};

export function parse(raw)
{
    if (!raw || length(raw) < 2) {
        return { ok: false, error: "packet too short" };
    }

    let offset = 0;
    const header = ord(raw, offset++);
    const routeType = header & 0x03;
    const payloadType = (header >> 2) & 0x0f;
    const payloadVersion = (header >> 6) & 0x03;

    if (payloadVersion !== PAYLOAD_VER_1) {
        return { ok: false, error: "unsupported payload version", payload_version: payloadVersion };
    }

    const parsed = {
        ok: true,
        raw: raw,
        header: header,
        route_type: routeType,
        route_type_name: routeTypeName(routeType),
        payload_type: payloadType,
        payload_type_name: payloadTypeName(payloadType),
        payload_version: payloadVersion,
        flood: routeType === ROUTE_TYPE_FLOOD || routeType === ROUTE_TYPE_TRANSPORT_FLOOD,
        direct: routeType === ROUTE_TYPE_DIRECT || routeType === ROUTE_TYPE_TRANSPORT_DIRECT
    };

    if (hasTransportCodes(routeType)) {
        if (offset + 4 > length(raw)) {
            return { ok: false, error: "partial transport codes" };
        }
        parsed.transport_codes = struct.unpack("<HH", raw, offset);
        offset += 4;
    }
    else {
        parsed.transport_codes = [0, 0];
    }

    if (offset >= length(raw)) {
        return { ok: false, error: "missing path info" };
    }

    const pathinfo = ord(raw, offset++);
    const hashSize = pathHashSize(pathinfo);
    if (!hashSize) {
        return { ok: false, error: "reserved path hash mode", pathinfo: pathinfo };
    }
    const pathBytes = pathByteLength(pathinfo);
    if (pathBytes < 0 || pathBytes > MAX_PATH_SIZE || offset + pathBytes > length(raw)) {
        return { ok: false, error: "partial or invalid path", pathinfo: pathinfo };
    }

    parsed.pathinfo = pathinfo;
    parsed.path_hash_size = hashSize;
    parsed.path_hash_count = pathHashCount(pathinfo);
    parsed.path = substr(raw, offset, pathBytes);
    offset += pathBytes;

    parsed.payload = substr(raw, offset);
    parsed.payload_len = length(parsed.payload);
    parsed.id = packetId(payloadType, pathinfo, parsed.payload);

    if (parsed.payload_len > MAX_PACKET_PAYLOAD) {
        parsed.warning = "payload exceeds documented MAX_PACKET_PAYLOAD";
    }

    switch (payloadType) {
        case PAYLOAD_TYPE_ADVERT:
            parsed.advert = parseAdvert(parsed.payload);
            break;
        case PAYLOAD_TYPE_PATH:
        case PAYLOAD_TYPE_REQ:
        case PAYLOAD_TYPE_RESPONSE:
        case PAYLOAD_TYPE_TXT_MSG:
            parsed.envelope = parseDirectEnvelope(parsed.payload);
            break;
        case PAYLOAD_TYPE_GRP_TXT:
        case PAYLOAD_TYPE_GRP_DATA:
            parsed.group = parseGroupEnvelope(parsed.payload);
            break;
        case PAYLOAD_TYPE_ACK:
            parsed.ack = parseAck(parsed.payload);
            break;
        default:
            break;
    }

    return parsed;
};

export function padBlock(buf)
{
    while (length(buf) % 32 != 0) {
        buf += "\u0000";
    }
    return buf;
};

export function makePacketHeader(payloadType, path, hashsize, prefixHash1, prefixHash2)
{
    hashsize = hashsize ?? 1;
    if (path) {
        const hashSize = pathHashSize(path.type ?? path.pathinfo ?? 0);
        if (hashSize > 0) {
            const count = length(path.path) / hashSize;
            const outCount = count > 0 ? count - 1 : 0;
            const pathInfo = encodePathInfo(hashSize, outCount);
            return chr(makeHeader(payloadType, ROUTE_TYPE_DIRECT, PAYLOAD_VER_1)) + chr(pathInfo) + substr(path.path, hashSize);
        }
    }

    const pathInfo = encodePathInfo(hashsize, 1);
    switch (hashsize) {
        case 3:
            return chr(makeHeader(payloadType, ROUTE_TYPE_FLOOD, PAYLOAD_VER_1)) + chr(pathInfo) + substr(struct.pack(">I", prefixHash2), 1, 3);
        case 2:
            return struct.pack(">BBH", makeHeader(payloadType, ROUTE_TYPE_FLOOD, PAYLOAD_VER_1), pathInfo, prefixHash2);
        case 1:
        default:
            return struct.pack("BBB", makeHeader(payloadType, ROUTE_TYPE_FLOOD, PAYLOAD_VER_1), pathInfo, prefixHash1);
    }
};

export function buildAdvertPayload(advert, privateKey, rxTime)
{
    let type = ADV_LATLON_MASK | ADV_NAME_MASK;
    type |= advert.role_type ?? ADV_TYPE_CHAT;
    const pos = advert.position ?? { latitude_i: 0, longitude_i: 0 };
    const name = advert.name ?? "";
    const appdata = struct.pack("<Bii", type, pos.latitude_i / 10, pos.longitude_i / 10) + name;
    const plain = advert.public_key + struct.pack("<I", rxTime) + appdata;
    const signature = crypto.sign(privateKey, advert.public_key, plain);
    return advert.public_key + struct.pack("<I", rxTime) + signature + appdata;
};

export function buildPlainTextPayload(rxTime, text)
{
    return struct.pack("<IB", rxTime, TEXT_TYPE_PLAIN) + substr(text, 0, MAX_TEXT_MESSAGE_LENGTH);
};
