// Shared-key and payload decode helpers for the new MeshCore TNC backend.
//
// This mirrors the key-cache behavior from meshcore.uc but is kept separate so
// the legacy UDP bridge backend remains untouched.

import * as struct from "struct";
import * as crypto from "crypto.crypto";
import * as node from "node";
import * as nodedb from "nodedb";
import * as channel from "channel";
import * as pkt from "meshcore_tnc_packet";

const SAVE_KEY = "meshcore_tnc.sharedkeys";

let sharedKeys = {};
let xPriv = {};
let xPub = {};
const recentKeys = {};
let dirty = false;

export function load()
{
    const data = platform.load(SAVE_KEY);
    if (data) {
        sharedKeys = data.sharedKeys ?? {};
        xPriv = data.xPriv ?? {};
        xPub = data.xPub ?? {};
    }
};

export function save()
{
    if (dirty) {
        platform.store(SAVE_KEY, {
            sharedKeys: sharedKeys,
            xPriv: xPriv,
            xPub: xPub
        });
        dirty = false;
    }
};

export function getSharedKey(priv, pub)
{
    const hkey = `${priv}${pub}`;
    let sharedkey = sharedKeys[hkey];
    if (!sharedkey) {
        let xpriv = xPriv[priv];
        if (!xpriv) {
            xpriv = crypto.ed25519_privkey_to_x25519(priv);
            xPriv[priv] = xpriv;
        }
        let xpub = xPub[pub];
        if (!xpub) {
            xpub = crypto.ed25519_pubkey_to_x25519(pub);
            xPub[pub] = xpub;
        }
        sharedkey = struct.unpack("32B", crypto.getSharedKey(xpriv, xpub));
        sharedKeys[hkey] = sharedkey;
        dirty = true;
    }
    return sharedkey;
};

export function getRecentKeys(fromhash, tohash)
{
    return recentKeys[`${fromhash}:${tohash}`];
};

export function addRecentKey(fromhash, tohash, from, to, sharedkey)
{
    const hkey = `${fromhash}:${tohash}`;
    const rkey = `${tohash}:${fromhash}`;
    push(recentKeys[hkey] ?? (recentKeys[hkey] = []), { from: from, to: to, key: sharedkey });
    push(recentKeys[rkey] ?? (recentKeys[rkey] = []), { from: to, to: from, key: sharedkey });
};

export function resolveDirectSecret(envelope)
{
    if (!envelope?.ok) {
        return null;
    }

    const fromhash = envelope.source_hash;
    const tohash = envelope.destination_hash;
    const mac = envelope.mac;
    const encrypted = envelope.ciphertext;

    const recents = getRecentKeys(fromhash, tohash);
    if (recents) {
        for (let i = 0; i < length(recents); i++) {
            const recent = recents[i];
            const hmac = crypto.sha256hmac(recent.key, encrypted);
            if (hmac[0] === mac[0] && hmac[1] === mac[1]) {
                return {
                    key: recent.key,
                    from: recent.from,
                    to: recent.to,
                    fromhash: fromhash,
                    tohash: tohash
                };
            }
        }
    }

    const me = node.getInfo();
    const fromnodes = nodedb.getNodesByPublickeyHash(fromhash, false);
    const tonodes = nodedb.getNodesByPublickeyHash(tohash, true);
    if (!me.is_unmessagable && node.getMeshcoreHash(1) === tohash) {
        push(tonodes, {
            me: true,
            id: node.id(),
            nodeinfo: me
        });
    }

    for (let i = 0; i < length(fromnodes); i++) {
        const fnode = fromnodes[i];
        if (fnode.nodeinfo?.is_unmessagable) {
            continue;
        }
        const frompublic = fnode.nodeinfo?.mc_public_key;
        if (!frompublic) {
            continue;
        }
        for (let j = 0; j < length(tonodes); j++) {
            const tnode = tonodes[j];
            if (tnode.nodeinfo?.is_unmessagable) {
                continue;
            }
            const toprivate = tnode.me ? tnode.nodeinfo.private_key : platform.getTargetById(tnode.id)?.private_key;
            if (!toprivate) {
                continue;
            }
            const key = getSharedKey(toprivate, frompublic);
            const hmac = crypto.sha256hmac(key, encrypted);
            if (hmac[0] === mac[0] && hmac[1] === mac[1]) {
                addRecentKey(fromhash, tohash, fnode.id, tnode.id, key);
                return {
                    key: key,
                    from: fnode.id,
                    to: tnode.id,
                    fromhash: fromhash,
                    tohash: tohash
                };
            }
        }
    }

    return null;
};

export function decryptDirect(parsed)
{
    const secret = resolveDirectSecret(parsed?.envelope);
    if (!secret) {
        return null;
    }
    const plain = crypto.decryptECB(secret.key, parsed.envelope.ciphertext);
    return {
        from: secret.from,
        to: secret.to,
        fromhash: secret.fromhash,
        tohash: secret.tohash,
        key: secret.key,
        plain: plain
    };
};

export function parseTextPlain(parsed, plain, fromNodeId)
{
    if (!plain || length(plain) < 5) {
        return null;
    }
    const timestampAndFlags = struct.unpack("<IB", plain);
    const flags = timestampAndFlags[1];
    const textType = flags >> 2;
    const attempt = flags & 3;
    let offset = 5;

    switch (textType) {
        case 0: // plain text
            break;
        case 2: // signed plain text, first four bytes are sender pubkey prefix
            offset += 4;
            break;
        case 1: // CLI command
        default:
            return null;
    }

    const text = rtrim(substr(plain, offset), "\u0000");
    const publicKey = nodedb.getNode(fromNodeId)?.nodeinfo?.mc_public_key;
    return {
        rx_time: timestampAndFlags[0],
        attempt: attempt,
        text_type: textType,
        text_message: text,
        checksum: publicKey ? slice(crypto.sha256hash(substr(plain, 0, offset) + text + publicKey), 0, 4) : null,
        signed_prefix_checked: false
    };
};

export function decryptTextMessage(parsed)
{
    const direct = decryptDirect(parsed);
    if (!direct) {
        return null;
    }
    const text = parseTextPlain(parsed, direct.plain, direct.from);
    if (!text) {
        return null;
    }
    return {
        from: direct.from,
        to: direct.to,
        rx_time: text.rx_time,
        attempt: text.attempt,
        text_message: text.text_message,
        checksum: text.checksum,
        signed_prefix_checked: text.signed_prefix_checked,
        key: direct.key
    };
};

export function decryptGroupText(parsed)
{
    if (!parsed?.group?.ok) {
        return null;
    }
    const group = parsed.group;
    const hashchannels = channel.getChannelsByMeshcoreHash(group.channel_hash);
    for (let i = 0; i < length(hashchannels); i++) {
        const key = hashchannels[i].symmetrickey;
        const hmac = crypto.sha256hmac(key, group.ciphertext);
        if (hmac[0] === group.mac[0] && hmac[1] === group.mac[1]) {
            const plain = crypto.decryptECB(key, group.ciphertext);
            const timestampAndFlags = struct.unpack("<IB", plain);
            if (timestampAndFlags[1] !== 0) {
                return null;
            }
            const fm = split(substr(plain, 5), ": ", 2);
            return {
                namekey: hashchannels[i].namekey,
                rx_time: timestampAndFlags[0],
                text_from: fm[0],
                from: nodedb.getNodeByMeshcoreLongname(fm[0])?.id ?? node.UNKNOWN,
                text_message: rtrim(fm[1], "\u0000"),
                weak_identity: true
            };
        }
    }
    return null;
};

export function getDirectSendKey(msg)
{
    const topublic = nodedb.getNode(msg.to)?.nodeinfo?.mc_public_key;
    const fromprivate = node.fromMe(msg) ? node.getInfo().private_key : platform.getTargetById(msg.from)?.private_key;
    const frompublic = nodedb.getNode(msg.from)?.nodeinfo?.mc_public_key;
    if (topublic && fromprivate && frompublic) {
        const tohash = ord(topublic);
        const fromhash = ord(frompublic);
        const sharedkey = getSharedKey(fromprivate, topublic);
        const recents = getRecentKeys(fromhash, tohash);
        if (recents) {
            let found = false;
            for (let i = 0; i < length(recents); i++) {
                if (recents[i].key === sharedkey) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                addRecentKey(fromhash, tohash, msg.from, msg.to, sharedkey);
            }
        }
        return {
            topublic: topublic,
            fromprivate: fromprivate,
            frompublic: frompublic,
            tohash: tohash,
            fromhash: fromhash,
            sharedkey: sharedkey
        };
    }
    return null;
};

export function encryptDirectText(msg)
{
    const keys = getDirectSendKey(msg);
    if (!keys) {
        return null;
    }
    const plain = pkt.buildPlainTextPayload(msg.rx_time, msg.data.text_message);
    const padded = pkt.padBlock(plain);
    const encrypted = crypto.encryptECB(keys.sharedkey, padded);
    const hmac = crypto.sha256hmac(keys.sharedkey, encrypted);
    return {
        keys: keys,
        plain: plain,
        encrypted: encrypted,
        hmac: hmac,
        payload: struct.pack("4B", keys.tohash, keys.fromhash, hmac[0], hmac[1]) + encrypted
    };
};

export function encryptGroupText(msg, chan, text)
{
    const plain = pkt.padBlock(pkt.buildPlainTextPayload(msg.rx_time, text));
    const encrypted = crypto.encryptECB(chan.symmetrickey, plain);
    const hmac = crypto.sha256hmac(chan.symmetrickey, encrypted);
    return struct.pack("3B", chan.meshcorehash, hmac[0], hmac[1]) + encrypted;
};
