import * as node from "node";
import * as nodedb from "nodedb";
import * as channel from "channel";
import * as message from "message";
import * as timers from "timers";
import * as router from "router";
import * as utils from "utils";

let enabled = false;

const MAX_MESSAGES = 100;
const SAVE_INTERVAL = 19 * 60;
const APRS_RETRY_WINDOW_SECONDS = 5;

// Small AREDN nodes cannot afford an unbounded in-memory copy of every
// conversation.  This is a global upper bound; channel-specific settings may
// still lower it.  MeshCore direct/group text remains available, but old
// traffic is deliberately bounded.
let configuredMaxMessages = MAX_MESSAGES;

const channelmessages = {};
const channelmessagesdirty = {};
const channelindex = {};

function loadMessages(namekey)
{
    if (!channelmessages[namekey]) {
        let changed = false;
        channelmessages[namekey] = platform.load(`messages.${namekey}`) ?? {
            max: configuredMaxMessages,
            count: 0,
            cursor: null,
            messages: [],
            badge: true,
            images: true,
            winlink: channel.isDirect(namekey)
        };
        if (channelmessages[namekey].max == null ||
            channelmessages[namekey].max > configuredMaxMessages) {
            channelmessages[namekey].max = configuredMaxMessages;
            changed = true;
        }
        const chanmessages = channelmessages[namekey].messages;
        while (length(chanmessages) > channelmessages[namekey].max) {
            shift(chanmessages);
            changed = true;
        }
        if (changed) channelmessagesdirty[namekey] = true;
        const index = {};
        channelindex[namekey] = index;
        for (let i = 0; i < length(chanmessages); i++) {
            const m = chanmessages[i];
            index[m.id] = true;
        }
        platform.badge(`messages.${namekey}`, channelmessages[namekey].badge ? channelmessages[namekey].count : 0);
    }
    return channelmessages[namekey];
}

export function saveMessages(namekey)
{
    const chanmessages = channelmessages[namekey];
    const messages = chanmessages.messages;
    const cursor = chanmessages.cursor;
    const max = chanmessages.max;
    const index = channelindex[namekey];
    while (length(messages) > max) {
        const m = shift(messages);
        delete index[m.id];
    }
    let count = 0;
    for (let i = length(messages) - 1; i >= 0; i--) {
        if (messages[i].id === cursor) {
            break;
        }
        count++;
    }
    chanmessages.count = count;
    if (count === length(messages)) {
        chanmessages.cursor = null;
    }
    channelmessagesdirty[namekey] = true;
    platform.badge(`messages.${namekey}`, chanmessages.badge ? chanmessages.count : 0);
};

function isAprsRetryCopy(chanmessages, msg, text, textfrom)
{
    if (!textfrom) {
        return false;
    }
    for (let i = length(chanmessages.messages) - 1; i >= 0; i--) {
        const prior = chanmessages.messages[i];
        const delta = msg.rx_time - prior.when;
        if (delta > APRS_RETRY_WINDOW_SECONDS) {
            break;
        }
        if (delta >= -APRS_RETRY_WINDOW_SECONDS &&
            uc(trim(prior.textfrom ?? "")) === uc(trim(textfrom)) &&
            prior.text === text) {
            return true;
        }
    }
    return false;
}

function addNamekeyMessage(namekey, msg)
{
    const chanmessages = loadMessages(namekey);
    if (!channelindex[namekey][msg.id]) {
        const text = utils.utf8validCopy(msg.data.text_message);
        const textfrom = utils.utf8validCopy(msg.data.text_from);
        if (isAprsRetryCopy(chanmessages, msg, text, textfrom)) {
            // Remember the alternate gateway/text-store ID for this runtime so
            // repeated sync responses do not need to scan the retained list.
            channelindex[namekey][msg.id] = true;
            return;
        }
        channelindex[namekey][msg.id] = true;
        push(chanmessages.messages, {
            id: msg.id,
            from: msg.from,
            when: msg.rx_time,
            text: text,
            textfrom: textfrom,
            structuredtext: msg.data.structured_text_message,
            replyid: msg.data.reply_id,
            checksum: msg.data.checksum
        });
        saveMessages(namekey);
        event.notify({ cmd: "text", namekey: namekey, id: msg.id }, `text ${namekey} ${msg.id}`);
    }
}

export function addMessage(msg)
{
    addNamekeyMessage(msg.namekey, msg);
};

export function getMessages(namekey)
{
    return loadMessages(namekey).messages;
};

export function getMessage(namekey, id)
{
    const chanmessages = loadMessages(namekey);
    if (chanmessages && channelindex[namekey][id]) {
        const messages = chanmessages.messages;
        for (let i = length(messages) - 1; i >= 0; i--) {
            const message = messages[i];
            if (message.id === id) {
                return message;
            }
        }
    }
    return null;
};

export function createMessage(to, namekey, text, structuredtext, replyto, last)
{
    const extra = {
        data: {}
    };
    if (replyto) {
        extra.data.reply_id = replyto;
    }
    if (last) {
        extra.data.last_id = last;
    }
    if (structuredtext) {
        extra.data.structured_text_message = structuredtext;
    }
    const msg = message.createMessage(to, null, namekey, "text_message", text, extra);
    addMessage(msg);
    return msg;
};

export function catchUpMessagesTo(namekey, id)
{
    const cm = loadMessages(namekey);
    if (channelindex[namekey][id] && id != cm.cursor) {
        cm.cursor = id;
        saveMessages(namekey);
    }
    return { count: cm.count, cursor: cm.cursor, last: cm.messages[length(cm.messages) - 1]?.id, max: cm.max, badge: cm.badge, images: cm.images, winlink: cm.winlink };
};

export function updateSettings(channels)
{
    for (let i = 0; i < length(channels); i++) {
        const channel = channels[i];
        const cm = loadMessages(channel.namekey);
        cm.badge = channel.badge;
        cm.max = channel.max;
        cm.images = channel.images;
        cm.winlink = channel.winlink;
        saveMessages(channel.namekey);
    }
};

export function updateChannelBadge(namekey, badge)
{
    const chan = loadMessages(namekey);
    if (chan.badge != badge) {
        chan.badge = badge;
        saveMessages(namekey);
    }
    if (channel.isDirect(namekey)) {
        const id = int(split(namekey, " ")[1]);
        const node = nodedb.getNode(id, false);
        if (node && node.nodeinfo && node.favorite != badge) {
            node.favorite = badge;
            nodedb.updateNode(node);
            event.notify({ cmd: "favorites" });
        }
    }
};

function addDirectMessage(msg, namekey)
{
    updateChannelBadge(namekey, true);
    addNamekeyMessage(namekey, msg);
}

export function createDirectMessage(to, text, structuredtext, replyto, last)
{
    const extra = {
        namekey: to,
        want_ack: true,
        data: {}
    };
    if (replyto) {
        extra.data.reply_id = replyto;
    }
    if (last) {
        extra.data.last_id = last;
    }
    if (structuredtext) {
        extra.data.structured_text_message = structuredtext;
    }
    const id = int(split(to, " ")[1]);
    const msg = message.createMessage(id, null, null, "text_message", text, extra);
    addDirectMessage(msg, to);
    return msg;
};

export function state(namekey)
{
    const cm = loadMessages(namekey);
    return { count: cm.count, cursor: cm.cursor, last: cm.messages[length(cm.messages) - 1]?.id, max: cm.max, badge: cm.badge, images: cm.images, winlink: cm.winlink };
};

export function setup(config)
{
    configuredMaxMessages = MAX_MESSAGES;
    const requestedMax = config.messages?.max;
    if (requestedMax != null) {
        configuredMaxMessages = int(requestedMax);
        if (configuredMaxMessages < 1) configuredMaxMessages = 1;
        if (configuredMaxMessages > MAX_MESSAGES) configuredMaxMessages = MAX_MESSAGES;
    }
    if (config.messages) {
        enabled = true;
        timers.setInterval("textmessages", SAVE_INTERVAL);
        const channels = config.channels;
        if (channels) {
            for (let i = 0; i < length(channels); i++)  {
                loadMessages(channels[i].namekey);
            }
        }
        const favs = nodedb.getNodes(true);
        for (let i = 0; i < length(favs); i++) {
            loadMessages(nodedb.namekey(favs[i].id));
        }
    }
};

function saveToPlatform()
{
    for (let namekey in channelmessages) {
        if (channelmessagesdirty[namekey]) {
            channelmessagesdirty[namekey] = false;
            platform.store(`messages.${namekey}`, channelmessages[namekey]);
        }
    }
}

export function shutdown()
{
    saveToPlatform();
};

export function isMessagable()
{
    return enabled;
};

export function tick()
{
    if (timers.tick("textmessages")) {
        saveToPlatform();
    }
};

function isLocalDirectMessage(msg)
{
    return channel.isDirect(msg.namekey) && (node.toMe(msg) || msg.metadata?.local_direct);
}

function isLocalChannelMessage(msg)
{
    if (!msg.namekey || !channel.getLocalChannelByNameKey(msg.namekey)) {
        return false;
    }
    if (node.forMe(msg)) {
        return true;
    }
    // TCP API and UDP channel/group messages on joined channels are intentionally
    // stored even when the RF destination is not Crow's native AREDN node id.
    return msg.metadata?.is_group_message || msg.transport === "meshcore" || msg.transport === "meshtastic";
}

export function process(msg)
{
    if (!enabled) {
        return;
    }
    if (msg.data?.text_message) {
        if (isLocalChannelMessage(msg)) {
            addMessage(msg);
        }
        else if (isLocalDirectMessage(msg)) {
            addDirectMessage(msg, nodedb.namekey(msg.from));
            if (msg.want_ack && node.toMe(msg)) {
                router.queue(message.createAckMessage(msg));
            }
        }
        else if (channel.isDirect(msg.namekey) && node.fromMe(msg)) {
            addDirectMessage(msg, msg.namekey);
        }
        // Keep a minimal direct-thread anchor so retained direct messages are
        // visible after restart. It contains no discovered name/position or
        // contact directory data; discovery-only records are still purged.
        if (msg.transport === "meshcore" && msg.metadata?.local_direct) {
            nodedb.createNode(msg.from);
            const thread = nodedb.getNode(msg.from, false);
            thread.favorite = true;
            const info = { platform: "meshcore-direct" };
            const prefix = msg.metadata?.meshcore_sender_prefix;
            if (prefix) {
                info.mc_public_key_prefix_b64 = prefix;
            }
            nodedb.updateNodeinfo(msg.from, info);
            nodedb.updateNode(thread);
        }
        else {
            nodedb.updateNode(nodedb.getNode(msg.from, false));
        }
    }
    else if (node.toMe(msg) && msg.data?.routing) {
        if (msg.data.routing.error_reason === 0) {
            const namekey = nodedb.namekey(msg.from);
            const message = getMessage(namekey, msg.data.request_id);
            if (message) {
                message.ack = true;
                saveMessages(namekey);
                event.notify({ cmd: "ack", namekey: namekey, id: msg.data.request_id }, `ack ${namekey} ${msg.data.request_id}`);
            }
        }
    }
};
