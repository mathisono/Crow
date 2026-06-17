#!/usr/bin/ucode
import * as fs from "fs";

const IMAGE_ROOTS = [ "/mnt/crow/images", "/tmp/apps/crow/images" ];
const FALLBACK_IMAGE = "/www/apps/crow/ix.png";

function fallback()
{
    return { path: FALLBACK_IMAGE, type: "image/png" };
}

function requestedImage()
{
    const q = getenv("QUERY_STRING") || "";
    const m = match(q, /(^|&)i=([A-Za-z0-9_-]{1,96}(\.jpg)?)(&|$)/);
    if (!m) {
        return fallback();
    }
    for (let i = 0; i < length(IMAGE_ROOTS); i++) {
        const path = `${IMAGE_ROOTS[i]}/${m[2]}`;
        const info = fs.stat(path);
        if (info && info.type === "file") {
            return { path, type: "image/jpeg" };
        }
    }
    return { path: `${IMAGE_ROOTS[0]}/${m[2]}`, type: "image/jpeg" };
}

let img = requestedImage();
let info = fs.stat(img.path);
if (!info || info.type !== "file") {
    img = fallback();
    info = fs.stat(img.path);
}

print("Status: 200 OK\r\n");
print(`Content-Type: ${img.type}\r\n`);
print(`Content-Length: ${info.size}\r\n`);
print("Cache-Control: no-store\r\n");
print("X-Content-Type-Options: nosniff\r\n");
print("\n");
const f = fs.open(img.path);
if (f) {
    for (;;) {
        const d = f.read(10240);
        if (!d) {
            break;
        }
        print(d);
    }
    f.close();
}
