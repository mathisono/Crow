#!/usr/bin/env python3
"""Exercise two live Crow GUIs through ChromeDriver and ui.js handlers."""

import json
import sys
import time
import urllib.request


NAMEKEY = "MeshCore izOH6cXN6mrJ5e26oRXNcg=="


def request(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:9515" + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.loads(response.read())


def new_session(url):
    result = request("POST", "/session", {
        "capabilities": {
            "alwaysMatch": {
                "browserName": "chrome",
                "goog:chromeOptions": {
                    "args": ["--headless", "--no-sandbox", "--disable-gpu", "--window-size=1400,1000"],
                },
            }
        }
    })
    sid = result.get("sessionId") or result.get("value", {}).get("sessionId")
    if not sid:
        raise RuntimeError(f"ChromeDriver session error: {result}")
    request("POST", f"/session/{sid}/url", {"url": url})
    return sid


def script(sid, value):
    result = request("POST", f"/session/{sid}/execute/sync", {"script": value, "args": []})
    if "value" not in result:
        raise RuntimeError(f"ChromeDriver script error: {result}")
    return result["value"]


def select_meshcore(sid):
    return script(sid, """
        const key = arguments[0];
        const el = [...document.querySelectorAll('#channels [data-namekey]')]
            .find(x => x.dataset.namekey === key);
        if (!el) return {ok:false, channels:document.querySelector('#channels')?.innerText || ''};
        el.click();
        return {
            ok:true,
            selected:document.querySelector('#channels .selected')?.dataset.namekey || null,
            text:document.querySelector('#texts')?.innerText || ''
        };
    """.replace("arguments[0]", json.dumps(NAMEKEY)))


def visible_text(sid, token):
    return script(sid, """
        const text = document.querySelector('#texts')?.innerText || '';
        return {
            selected:document.querySelector('#channels .selected')?.dataset.namekey || null,
            has_token:text.includes(arguments[0])
        };
    """.replace("arguments[0]", json.dumps(token)))


def post_via_ui(sid, token):
    return script(sid, """
        const t = document.querySelector('#post textarea');
        if (!t) return {ok:false, error:'textarea missing'};
        t.value = arguments[0];
        t.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter', bubbles:true}));
        return {ok:true, selected:document.querySelector('#channels .selected')?.dataset.namekey || null};
    """.replace("arguments[0]", json.dumps(token)))


def close(sid):
    try:
        request("DELETE", f"/session/{sid}")
    except Exception:
        pass


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} HUB5_URL BB5_URL", file=sys.stderr)
        return 2
    hub = new_session(sys.argv[1])
    bb5 = new_session(sys.argv[2])
    try:
        time.sleep(5)
        print("hub5_select", json.dumps(select_meshcore(hub), separators=(",", ":")))
        print("bb5_select", json.dumps(select_meshcore(bb5), separators=(",", ":")))
        time.sleep(2)

        a2b = "GUI-DOM3-A2B-20260826T204500"
        print("bb5_before_a2b", json.dumps(visible_text(bb5, a2b), separators=(",", ":")))
        print("hub5_post", json.dumps(post_via_ui(hub, a2b), separators=(",", ":")))
        time.sleep(12)
        print("bb5_after_a2b", json.dumps(visible_text(bb5, a2b), separators=(",", ":")))

        b2a = "GUI-DOM3-B2A-20260826T204600"
        print("hub5_before_b2a", json.dumps(visible_text(hub, b2a), separators=(",", ":")))
        print("bb5_post", json.dumps(post_via_ui(bb5, b2a), separators=(",", ":")))
        time.sleep(12)
        print("hub5_after_b2a", json.dumps(visible_text(hub, b2a), separators=(",", ":")))
        return 0
    finally:
        close(hub)
        close(bb5)


if __name__ == "__main__":
    raise SystemExit(main())
