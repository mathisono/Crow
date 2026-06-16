// Security hardening layer for ui.js.
// Loaded after ui.js; overrides HTML-producing helpers that render mesh-sourced data.

const safeDiv = document.createElement("div");

function esc(value)
{
    safeDiv.innerText = String(value ?? "");
    return safeDiv.innerHTML;
}

function attr(value)
{
    return esc(value).replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function safeClass(value)
{
    return String(value ?? "").replace(/[^A-Za-z0-9_-]/g, "");
}

function safeInt(value, fallback = 0)
{
    const n = Number.parseInt(value, 10);
    return Number.isFinite(n) ? n : fallback;
}

function safeBoolClass(value)
{
    return value ? "true" : "";
}

function safeUrl(value)
{
    try {
        const u = new URL(String(value ?? ""), window.location.origin);
        if (u.protocol === "http:" || u.protocol === "https:" || u.protocol === "mailto:") {
            return attr(u.href);
        }
    }
    catch (_) {
    }
    return "#";
}

function linkifyEscaped(escapedText)
{
    return escapedText.replace(/https?:\/\/[^ \t&lt;&quot;&#39;]+/g, v => {
        const u = safeUrl(v);
        return `<a target="_blank" rel="noopener noreferrer" href="${u}">${esc(v)}</a>`;
    });
}

// Replace ui.js T() with a null-safe escaper.
function T(text)
{
    return esc(String(text ?? "").trim());
}

function htmlChannel(channel)
{
    const nk = String(channel.namekey ?? "").split(" ");
    const namekey = attr(channel.namekey);
    const label = channel.meshtastic ? "Meshtastic" : esc(nk[0] ?? "");
    return `<div class="channel ${rightSelection === channel.namekey ? "selected" : ""}" data-namekey="${namekey}" onclick="showNamekey('${attr(channel.namekey)}')">
        <div class="n">
            <div class="t">${label}</div>
        </div>
        <div class="unread">${safeInt(channel.state?.count) > 0 ? safeInt(channel.state.count) : ''}</div>
    </div>`;
}

function htmlNode(node)
{
    const namekey = `DirectMessages ${safeInt(node.num)}`;
    const platform = safeClass(node.platform);
    const filter = `${node.short_name ?? ""} ${node.long_name ?? ""} ${node.platform === "native" ? "aredn" : node.platform ?? ""}`.toLowerCase();
    let filtered = false;
    if (activeFilter && filter.indexOf(activeFilter) === -1) {
        filtered = true;
    }
    return `<div id="${safeInt(node.num)}" class="node ${platform} ${rightSelection === namekey ? 'selected' : ''}" ${filtered ? 'style="display:none"' : ''} data-namekey="${attr(namekey)}" data-filter="${attr(filter)}" onclick="showNamekey('${attr(namekey)}')">
        <div class="s" style="color:${attr(node.colors?.fcolor)};background-color:${attr(node.colors?.bcolor)}">${esc(node.short_name)}</div>
        ${node.platform ? '<div class="logo"></div>' : ''}
        <div class="m">
            <div class="l">${esc(node.long_name)}</div>
            <div class="r">${esc(node.rolename)}</div>
            <div class="t">${esc(new Date(1000 * safeInt(node.lastseen)).toLocaleString())}</div>
        </div>
        <div class="unread">${safeInt(node.state?.count) > 0 ? safeInt(node.state.count) : ""}</div>
        ${node.favorite ? '<div class="star true"></div>' : ''}
    </div>`;
}

function htmlNodeDetail(node)
{
    let map = "";
    if (node.mapurl) {
        const u = safeUrl(node.mapurl);
        map = `<a class="map" href="${u}" target="_blank" rel="noopener noreferrer"><iframe src="${u}"></iframe><div class="overlay"></div></a>`;
    }
    let hops = "";
    if (node.hops !== null && node.hops !== undefined) {
        hops = `<div class="r"><div>Hops</div><div>${esc(node.hops)}</div></div>`;
    }
    const platform = safeClass(node.platform);
    const platformName = node.platform == "native" ? "AREDN" : node.platform == "meshcore" ? "MeshCore" : "Meshtastic";
    return `<div class="node-detail">
        <div class="node ${platform}">
            <div class="s" style="color:${attr(node.colors?.fcolor)};background-color:${attr(node.colors?.bcolor)}">${esc(node.short_name)}</div>
            ${node.platform ? '<div class="logo"></div>' : ''}
            <div class="m">
                <div class="l">${esc(node.long_name)}<div class="star ${safeBoolClass(node.favorite)}" onclick="toggleFav(event,${safeInt(node.num)})"></div></div>
                <div class="r"><div>User Id</div><div>${esc(node.id)}</div></div>
                <div class="r"><div>Platform</div><div>${esc(platformName)}</div></div>
                ${node.public_key ? '<div class="r"><div>Public Key</div><div>' + esc(node.public_key) + '</div></div>' : ''}
                ${hops}
                ${node.version ? '<div class="r"><div>Version</div><div>' + esc(node.version) + '</div></div>' : ''}
                <div class="r"><div>Role</div><div>${esc(node.rolename)}</div></div>
                <div class="t"><div>Last seen</div><div>${esc(new Date(1000 * safeInt(node.lastseen)).toLocaleString())}</div></div>
            </div>
        </div>
        ${map}
    </div>`;
}

function htmlText(text, useimage)
{
    let n = nodes[text.from];
    if (!n) {
        if (text.textfrom) {
            const hash = sha256(String(text.textfrom).replace(/[^\x00-\x7F]/g, ""));
            const from = (hash[0] << 24) + (hash[1] << 16) + (hash[2] << 8) + hash[3];
            n = {
                short_name: makeShortName(String(text.textfrom)),
                long_name: text.textfrom,
                colors: nodeColors(from),
                platform: "meshcore"
            };
        }
        else {
            const id = safeInt(text.from).toString(16);
            n = {
                short_name: id.substr(-4),
                long_name: id.substr(-4),
                colors: nodeColors(text.from)
            };
        }
    }
    let plaintext = T(text.text);
    let reply = "";
    if (text.replyid) {
        const r = texts.findLast(t => t.id == text.replyid);
        if (r) {
            reply = `<div class="r"><div>${T(String(r.text ?? "").replace(/\n/g," "))}</div></div>`;
        }
    }
    else if (plaintext.indexOf("@[") === 0) {
        const rs = [];
        while (plaintext.indexOf("@[") === 0) {
            const end = plaintext.indexOf("]");
            if (end === -1) {
                break;
            }
            rs.push(plaintext.substring(2, end));
            plaintext = plaintext.substring(end + 1).trim();
        }
        reply = `<div class="r"><div>${rs.map(esc).join(" | ")}</div></div>`;
    }
    let textmsg = null;
    const structuredtext = text.structuredtext && text.structuredtext[0];
    if (structuredtext) {
        const wl = structuredtext.winlink;
        if (winlink && wl) {
            let show = "";
            if (winlink[wl.id]) {
                show = `onclick="showNamekey('winlink-express-show ${safeInt(text.id)}')"`;
            }
            textmsg = `<div class="b"><div class="ack ${text.ack ? 'true' : ''}"></div><div class="w" ${show}><div class="i">Winlink</div><span>${esc(String(wl.id ?? "").replace("/", " | "))}</span></div></div>`;
        }
        const im = structuredtext.image;
        if (useimage && im) {
            const u = safeUrl(im.url);
            textmsg = `<div class="b"><div class="ack ${text.ack ? 'true' : ''}"></div><div class="i"><a target="_blank" rel="noopener noreferrer" href="${u}"><img loading="lazy" src="${u}" onerror="this.src='/apps/crow/ix.png'"></a></div></div>`;
        }
    }
    if (!textmsg) {
        textmsg = `<div class="b"><div class="ack ${text.ack ? 'true' : ''}"></div><div class="t">`
            + linkifyEscaped(plaintext).replace(/@\[([^\]]+)\]/g, (_, w) => `<span>${esc(w)}</span>`)
            + '</div><a href="#" class="re" onclick="setupReply(event)">Reply</a></div>';
    }
    return `<div id="${safeInt(text.id)}" class="text ${n.num != me.num ? '' : 'me ' + safeClass(me.align)} ${safeClass(n.platform)}">
        ${reply}
        <div>
            <div class="s" style="color:${attr(n.colors?.fcolor)};background-color:${attr(n.colors?.bcolor)}">${esc(n.short_name)}</div>
            ${n.platform ? '<div class="logo"></div>' : ''}
            <div class="c">
                <div class="l">${esc(n.long_name)}<div>&nbsp;${esc(new Date(1000 * safeInt(text.when)).toLocaleString())}</div></div>
                ${textmsg}
            </div>
        </div>
    </div>`;
}

function htmlCommand(reply)
{
    const lines = `<div>${(reply ?? []).map(esc).join("</div><div>")}</div>`;
    return `<div class="text me command ${safeClass(me.align)}">
        <div>
            <div class="s"></div>
            <div class="c"><div class="b"><div class="t">${lines}</div></div></div>
        </div>
    </div>`;
}

function backendOptions(selected)
{
    if (!aprsBackends || aprsBackends.length === 0) {
        return '';
    }
    let opts = `<option value=""${!selected ? ' selected' : ''}>(default)</option>`;
    for (let i = 0; i < aprsBackends.length; i++) {
        const b = aprsBackends[i];
        const key = b.key || b;
        const label = b.label || b;
        opts += `<option value="${attr(key)}"${selected === key ? ' selected' : ''}>${esc(label)}</option>`;
    }
    return opts;
}

function htmlWinlinkMenu(menu)
{
    let main = "";
    for (let i = 0; i < menu.length; i++) {
        const submenu = menu[i][1];
        let sub = "";
        for (let j = 0; j < submenu.length; j++) {
            const form = `${menu[i][0]}/${submenu[j]}`;
            sub += `<div onclick="showNamekey('winlink-express-form ${attr(form)}')">${esc(submenu[j])}</div>`;
        }
        main += `<div><div>${esc(menu[i][0])}</div><div><div>${sub}</div></div></div>`;
    }
    return main;
}
