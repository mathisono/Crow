// MeshCore TNC/KISS frame codec.
//
// This module is intentionally standalone so it can be unit-tested without
// touching the existing meshcore.uc UDP multicast backend.

const FEND = 0xC0;
const FESC = 0xDB;
const TFEND = 0xDC;
const TFESC = 0xDD;

const CMD_DATA = 0x00;
const CMD_SETHARDWARE = 0x06;

export function createState()
{
    return {
        buf: "",
        esc: false,
        inframe: false
    };
};

function appendByte(s, b)
{
    return s + chr(b & 0xff);
}

export function command(typebyte)
{
    return typebyte & 0x0f;
};

export function port(typebyte)
{
    return typebyte >> 4;
};

export function isDataFrame(frame)
{
    return frame && frame.command === CMD_DATA;
};

export function isSetHardwareFrame(frame)
{
    return frame && frame.command === CMD_SETHARDWARE;
};

export function parseFrame(raw)
{
    if (!raw || length(raw) < 1) {
        return null;
    }
    const typebyte = ord(raw, 0);
    return {
        typebyte: typebyte,
        port: port(typebyte),
        command: command(typebyte),
        data: substr(raw, 1)
    };
};

export function feed(state, data)
{
    const out = [];
    if (!state) {
        state = createState();
    }
    if (!data) {
        return out;
    }

    for (let i = 0; i < length(data); i++) {
        const b = ord(data, i);

        if (b === FEND) {
            if (state.inframe && length(state.buf) > 0) {
                const frame = parseFrame(state.buf);
                if (frame) {
                    push(out, frame);
                }
            }
            state.buf = "";
            state.esc = false;
            state.inframe = true;
            continue;
        }

        if (!state.inframe) {
            continue;
        }

        if (state.esc) {
            if (b === TFEND) {
                state.buf = appendByte(state.buf, FEND);
            }
            else if (b === TFESC) {
                state.buf = appendByte(state.buf, FESC);
            }
            else {
                // Invalid escape. Keep the escaped byte literally so the
                // caller can decide whether the resulting payload is valid.
                state.buf = appendByte(state.buf, b);
            }
            state.esc = false;
            continue;
        }

        if (b === FESC) {
            state.esc = true;
            continue;
        }

        state.buf = appendByte(state.buf, b);
    }

    return out;
};

export function escape(data)
{
    let out = "";
    for (let i = 0; i < length(data); i++) {
        const b = ord(data, i);
        switch (b) {
            case FEND:
                out += chr(FESC) + chr(TFEND);
                break;
            case FESC:
                out += chr(FESC) + chr(TFESC);
                break;
            default:
                out += chr(b);
                break;
        }
    }
    return out;
};

export function encode(typebyte, data)
{
    return chr(FEND) + escape(chr(typebyte & 0xff) + (data ?? "")) + chr(FEND);
};

export function encodeData(data, kissport)
{
    kissport = kissport ?? 0;
    return encode((kissport << 4) | CMD_DATA, data);
};

export function encodeSetHardware(subcmd, data, kissport)
{
    kissport = kissport ?? 0;
    return encode((kissport << 4) | CMD_SETHARDWARE, chr(subcmd & 0xff) + (data ?? ""));
};
