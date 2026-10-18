.pragma library

// Pure logic of the system sections (Wi-Fi, Bluetooth, Sound, Displays): parsers of the backend tools' output,
// argument vectors of the actions, display arrangement. No I/O here. The read-only queries and the action
// programs must stay in step with apps/settings/src/systemguard.cpp: tests/shell/settings_system_guard.sh runs every
// QUERY entry (and a profile-SSID query) through the real guard and fails if one is refused.
// Every tool runs in the C locale (Backend forces LC_ALL=C): the parsers read the English output.

// ---- Read-only queries (the only commands a dev session may run; see systemguard.cpp) ----------------------------

var QUERY = {
    wifiRadio: ["nmcli", "-t", "-f", "WIFI", "radio"],
    // SSID-HEX, not SSID: a network name may hold any byte (newline, ':', backslash); hex can never fake a row or a field.
    wifiList: ["nmcli", "-t", "-f", "IN-USE,SSID-HEX,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no"],
    wifiProfiles: ["nmcli", "-t", "-f", "UUID,TYPE", "connection", "show"],
    wifiDevices: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device"],
    btShow: ["bluetoothctl", "show"],
    btPaired: ["bluetoothctl", "devices", "Paired"],
    btConnected: ["bluetoothctl", "devices", "Connected"],
    audio: ["wpctl", "status"]
};

// SSID of one saved profile (a UUID of parseWifiProfiles); null for anything else.
function wifiProfileSsidQuery(uuid) {
    return validUuid(uuid) ? ["nmcli", "-t", "-f", "802-11-wireless.ssid", "connection", "show", "uuid", uuid] : null;
}

function validUuid(s) {
    return typeof s === "string" && /^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.test(s);
}

// ---- Stable-id models ----------------------------------------------------------------------------------------------

// Make a ListModel hold exactly `items` (plain objects with scalar fields, in order), keyed by the field `keyName`:
// rows of keys that vanished are removed, new keys are inserted, kept rows are moved only when the order changed and
// updated only in the fields that differ. A kept row is never rebuilt, so its delegate keeps focus and selection.
function syncModel(model, items, keyName) {
    const wanted = {};
    for (const it of items)
        wanted[it[keyName]] = true;
    for (let i = model.count - 1; i >= 0; i--) {
        if (!wanted[model.get(i)[keyName]])
            model.remove(i);
    }
    for (let i = 0; i < items.length; i++) {
        const it = items[i];
        if (i >= model.count) {
            model.append(it);
            continue;
        }
        if (model.get(i)[keyName] !== it[keyName]) {
            let j = -1;
            for (let k = i + 1; k < model.count; k++) {
                if (model.get(k)[keyName] === it[keyName]) {
                    j = k;
                    break;
                }
            }
            if (j < 0) {
                model.insert(i, it);
                continue;
            }
            model.move(j, i, 1);
        }
        const row = model.get(i);
        for (const p of Object.keys(it)) {
            if (row[p] !== it[p])
                model.setProperty(i, p, it[p]);
        }
    }
}

// ---- nmcli -------------------------------------------------------------------------------------------------------

// Fields of one `nmcli -t` line: ':' separates, "\:" and "\\" are escapes.
function splitTerse(line) {
    const out = [];
    let cur = "";
    for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (c === "\\" && i + 1 < line.length) {
            cur += line[i + 1];
            i++;
        } else if (c === ":") {
            out.push(cur);
            cur = "";
        } else {
            cur += c;
        }
    }
    out.push(cur);
    return out;
}

// "enabled" / "disabled" of `nmcli -t -f WIFI radio`; null when the output is not that (no NetworkManager).
function parseWifiRadio(text) {
    const v = String(text).trim();
    return v === "enabled" ? true : v === "disabled" ? false : null;
}

// Text of a hex string of UTF-8 bytes ("486F"): {text, valid}. Bad sequences become U+FFFD and valid is false; so is it
// for malformed hex. Never throws.
function hexToText(hex) {
    const h = String(hex).trim();
    if (h.length % 2 !== 0 || !/^[0-9A-Fa-f]*$/.test(h))
        return {text: "", valid: false};
    const b = [];
    for (let i = 0; i < h.length; i += 2)
        b.push(parseInt(h.substr(i, 2), 16));
    let text = "";
    let valid = true;
    let i = 0;
    while (i < b.length) {
        const c = b[i];
        if (c < 0x80) {
            text += String.fromCharCode(c);
            i++;
            continue;
        }
        let n = 0;
        let cp = 0;
        if (c >= 0xC2 && c <= 0xDF) {
            n = 1;
            cp = c & 0x1F;
        } else if (c >= 0xE0 && c <= 0xEF) {
            n = 2;
            cp = c & 0x0F;
        } else if (c >= 0xF0 && c <= 0xF4) {
            n = 3;
            cp = c & 0x07;
        }
        let ok = n > 0;
        for (let k = 1; ok && k <= n; k++) {
            if (i + k >= b.length || (b[i + k] & 0xC0) !== 0x80)
                ok = false;
            else
                cp = cp * 64 + (b[i + k] & 0x3F);
        }
        const min = n === 1 ? 0x80 : n === 2 ? 0x800 : 0x10000;
        if (!ok || cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            text += "\uFFFD";
            valid = false;
            i++;
            continue;
        }
        text += String.fromCodePoint(cp);
        i += n + 1;
    }
    return {text: text, valid: valid};
}

// Uppercase hex of the UTF-8 bytes of a string ("Home" -> "486F6D65").
function textToHex(text) {
    const s = unescape(encodeURIComponent(String(text)));
    let out = "";
    for (let i = 0; i < s.length; i++)
        out += (s.charCodeAt(i) < 16 ? "0" : "") + s.charCodeAt(i).toString(16).toUpperCase();
    return out;
}

// Control characters of a network name replaced by U+FFFD, so that a crafted name shows as one line of text.
function printable(text) {
    return String(text).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, "\uFFFD");
}

// Visible networks of `nmcli -t -f IN-USE,SSID-HEX,SIGNAL,SECURITY dev wifi list`: one per SSID and security (the
// strongest access point; the connected one wins), connected first, then by signal. Flat objects with the stable id
// `key` (SSID bytes + security): {key, hex, ssid, label, strength (0-100), security, secured, enterprise, active,
// valid (the name can be passed to nmcli as it is)}. Hidden networks (empty SSID) are skipped.
function parseWifiList(text) {
    const best = {};
    for (const line of String(text).split("\n")) {
        if (line.trim() === "")
            continue;
        const f = splitTerse(line);
        if (f.length !== 4 || f[1].trim() === "")
            continue;
        const name = hexToText(f[1]);
        if (name.text === "")
            continue;
        const security = f[3].trim() === "--" ? "" : f[3].trim();
        const hex = f[1].trim().toUpperCase();
        const net = {
            key: hex + "|" + security,
            hex: hex,
            ssid: name.text,
            label: printable(name.text),
            strength: Math.max(0, Math.min(100, parseInt(f[2], 10) || 0)),
            security: security,
            secured: security !== "",
            enterprise: security.indexOf("802.1X") >= 0,
            active: f[0].trim() === "*",
            valid: name.valid && plainName(name.text)
        };
        const old = best[net.key];
        if (!old || (net.active && !old.active) || (net.active === old.active && net.strength > old.strength))
            best[net.key] = net;
    }
    const list = Object.keys(best).map(k => best[k]);
    list.sort((a, b) => (a.active === b.active ? b.strength - a.strength || (a.key < b.key ? -1 : 1) : a.active ? -1 : 1));
    return list;
}

// UUIDs of the saved Wi-Fi profiles of `nmcli -t -f UUID,TYPE connection show`.
function parseWifiProfiles(text) {
    const out = [];
    for (const line of String(text).split("\n")) {
        const f = splitTerse(line);
        if (f.length === 2 && f[1] === "802-11-wireless" && validUuid(f[0]))
            out.push(f[0]);
    }
    return out;
}

// SSID, as uppercase hex of its UTF-8 bytes (comparable with a list row's `hex`), from the output of
// `nmcli -t -f 802-11-wireless.ssid connection show uuid <uuid>`; "" when the output is not that. One field only, so
// the whole rest of the output is the value: a name with a newline or a colon cannot be mistaken for anything else.
function parseProfileSsid(text) {
    const prefix = "802-11-wireless.ssid:";
    let t = String(text);
    if (t.indexOf(prefix) !== 0)
        return "";
    t = t.slice(prefix.length);
    if (t.slice(-1) === "\n")
        t = t.slice(0, -1);
    let value = "";
    for (let i = 0; i < t.length; i++) {
        if (t[i] === "\\" && i + 1 < t.length) {
            value += t[i + 1];
            i++;
        } else {
            value += t[i];
        }
    }
    return value === "" ? "" : textToHex(value);
}

// The first Wi-Fi interface of `nmcli -t -f DEVICE,TYPE,STATE device`: {name, connected}, null when there is none.
function parseWifiDevice(text) {
    for (const line of String(text).split("\n")) {
        const f = splitTerse(line);
        if (f.length >= 3 && f[1] === "wifi")
            return {name: f[0], connected: f[2] === "connected"};
    }
    return null;
}

// Signal glyph of the shell's icon set for a 0-100 strength.
function wifiGlyph(signal) {
    return signal >= 67 ? "wifi-3" : signal >= 34 ? "wifi-2" : "wifi-1";
}

// What a click on a network does; `known` maps the SSID hex of each saved profile to its UUID.
// "current" (already connected), "known" (saved profile with that SSID), "open" (no password) or
// "password" (secured and new: the password flow lives in Quick Settings).
function wifiClickKind(net, known) {
    if (net.active)
        return "current";
    if (known[net.hex] !== undefined)
        return "known";
    return net.secured ? "password" : "open";
}

// ---- bluetoothctl ------------------------------------------------------------------------------------------------

function stripTerminal(text) {
    return String(text).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/[\x01\x02\r]/g, "");
}

// {present, powered} of `bluetoothctl show`.
function parseBtShow(text) {
    const t = stripTerminal(text);
    const present = /^Controller\s+[0-9A-Fa-f:]{17}/m.test(t);
    return {present: present, powered: present && /^\s*Powered:\s*yes\s*$/m.test(t)};
}

// [{mac, name}] of `bluetoothctl devices [Paired|Connected]`.
function parseBtDevices(text) {
    const out = [];
    for (const line of stripTerminal(text).split("\n")) {
        const m = /^Device\s+([0-9A-Fa-f:]{17})\s*(.*)$/.exec(line.trim());
        if (m)
            out.push({mac: m[1].toUpperCase(), name: m[2].trim() !== "" ? m[2].trim() : m[1].toUpperCase()});
    }
    return out;
}

// Paired devices with their connection state, connected first then by name.
function bluetoothDevices(paired, connected) {
    const on = {};
    for (const d of connected)
        on[d.mac] = true;
    const list = paired.map(d => ({mac: d.mac, name: d.name, connected: on[d.mac] === true}));
    list.sort((a, b) => (a.connected === b.connected ? (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1) : a.connected ? -1 : 1));
    return list;
}

// ---- wpctl -------------------------------------------------------------------------------------------------------

// `wpctl status`: {sinks, sources}, each [{id, name, isDefault, volume (0-1.5), muted}]. Only the Sinks and Sources
// sections of the Audio block carry volumes; other sections (devices, streams, video) are ignored.
function parseAudio(text) {
    const out = {sinks: [], sources: []};
    let section = "";
    for (const raw of String(text).split("\n")) {
        const line = raw.replace(/[│├└─]/g, " ").trim();
        const head = /^([A-Za-z ]+):$/.exec(line);
        if (head) {
            section = head[1];
            continue;
        }
        if (/^[A-Za-z]+$/.test(line)) {
            section = line; // "Audio", "Video", "Settings"
            continue;
        }
        if (section !== "Sinks" && section !== "Sources")
            continue;
        const m = /^(\*)?\s*(\d+)\.\s+(.*?)\s+\[vol:\s*([0-9.]+)(\s+MUTED)?\]$/.exec(line);
        if (!m)
            continue;
        const dev = {id: parseInt(m[2], 10), name: m[3], isDefault: m[1] === "*", volume: parseFloat(m[4]), muted: m[5] !== undefined};
        (section === "Sinks" ? out.sinks : out.sources).push(dev);
    }
    return out;
}

function defaultOf(list) {
    for (const d of list) {
        if (d.isDefault)
            return d;
    }
    return null;
}

// Volume as a whole percent for display.
function percent(volume) {
    return Math.round(volume * 100);
}

// Output glyph of the shell's icon set for a volume and mute state.
function volumeGlyph(volume, muted) {
    return muted || volume <= 0 ? "volume-mute" : volume < 0.34 ? "volume-1" : volume < 0.67 ? "volume-2" : "volume-3";
}

// ---- Actions (argument vectors; null for anything invalid, so a bad value never reaches a process) --------------------

function plainName(s) {
    return typeof s === "string" && s !== "" && s.length <= 255 && s[0] !== "-" && !/[\x00-\x1f]/.test(s);
}

function wifiRadio(on) {
    return ["nmcli", "radio", "wifi", on ? "on" : "off"];
}

function wifiConnectKnown(uuid) {
    return validUuid(uuid) ? ["nmcli", "connection", "up", "uuid", uuid] : null;
}

function wifiConnectOpen(ssid) {
    return plainName(ssid) && ssid.indexOf("\uFFFD") < 0 ? ["nmcli", "device", "wifi", "connect", ssid] : null;
}

function wifiDisconnect(device) {
    return typeof device === "string" && /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$/.test(device) ? ["nmcli", "device", "disconnect", device] : null;
}

function btPower(on) {
    return ["bluetoothctl", "power", on ? "on" : "off"];
}

function btConnect(mac, connect) {
    return typeof mac === "string" && /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/.test(mac) ? ["bluetoothctl", connect ? "connect" : "disconnect", mac] : null;
}

function validId(id) {
    return Number.isInteger(id) && id >= 0 && id < 1000000000;
}

function setDefaultDevice(id) {
    return validId(id) ? ["wpctl", "set-default", String(id)] : null;
}

function setVolume(id, volume) {
    if (!validId(id) || typeof volume !== "number" || isNaN(volume))
        return null;
    return ["wpctl", "set-volume", String(id), (Math.max(0, Math.min(1, volume))).toFixed(2)];
}

function setMute(id, muted) {
    return validId(id) ? ["wpctl", "set-mute", String(id), muted ? "1" : "0"] : null;
}

// ---- Displays ----------------------------------------------------------------------------------------------------

// "1920 × 1080" (physical pixels) of a screen from Backend.screens().
function resolutionText(s) {
    return s.pixelWidth + " × " + s.pixelHeight;
}

// Refresh rate in hertz without trailing zeros ("60", "59.94"); "" when the compositor reports none.
function refreshHz(s) {
    if (!(s.refreshRate > 0))
        return "";
    const r = Math.round(s.refreshRate * 100) / 100;
    return String(r);
}

// Scale in percent ("100", "150", "125").
function scalePercent(s) {
    return String(Math.round((s.scale > 0 ? s.scale : 1) * 100));
}

// Arrangement preview: the screens' logical rectangles fitted into a box, aspect kept, centred. [{name, x, y, w, h,
// primary}] in box pixels; each rectangle is at least `minSide` pixels so that a tiny output stays visible.
function arrangement(screens, boxW, boxH, gap, minSide) {
    if (screens.length === 0 || boxW <= 0 || boxH <= 0)
        return [];
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const s of screens) {
        x0 = Math.min(x0, s.x);
        y0 = Math.min(y0, s.y);
        x1 = Math.max(x1, s.x + s.width);
        y1 = Math.max(y1, s.y + s.height);
    }
    const w = Math.max(1, x1 - x0);
    const h = Math.max(1, y1 - y0);
    const k = Math.min((boxW - 2 * gap) / w, (boxH - 2 * gap) / h);
    const ox = (boxW - w * k) / 2;
    const oy = (boxH - h * k) / 2;
    return screens.map(s => ({
            name: s.name,
            primary: s.primary === true,
            x: ox + (s.x - x0) * k,
            y: oy + (s.y - y0) * k,
            w: Math.max(minSide, s.width * k),
            h: Math.max(minSide, s.height * k)
        }));
}
