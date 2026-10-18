.pragma library

// Pure logic of the system sections (Wi-Fi, Bluetooth, Sound, Displays): parsers of the backend tools' output,
// argument vectors of the actions, display arrangement. No I/O here. The read-only queries and the action
// programs must stay in step with apps/settings/src/systemguard.cpp (tests/unit/tst_settingssystem.qml checks it).

// ---- Read-only queries (the only commands a dev session may run; see systemguard.cpp) ----------------------------

var QUERY = {
    wifiRadio: ["nmcli", "-t", "-f", "WIFI", "radio"],
    wifiList: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no"],
    wifiProfiles: ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"],
    wifiDevices: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device"],
    btShow: ["bluetoothctl", "show"],
    btPaired: ["bluetoothctl", "devices", "Paired"],
    btConnected: ["bluetoothctl", "devices", "Connected"],
    audio: ["wpctl", "status"]
};

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

// Visible networks, one per SSID (strongest access point; the connected one wins), connected first, then by signal.
// [{ssid, signal (0-100), security, secured, enterprise, active}]. Hidden networks (empty SSID) are skipped.
function parseWifiList(text) {
    const best = {};
    for (const line of String(text).split("\n")) {
        if (line.trim() === "")
            continue;
        const f = splitTerse(line);
        if (f.length < 4 || f[1] === "")
            continue;
        const security = f[3].trim() === "--" ? "" : f[3].trim();
        const net = {
            ssid: f[1],
            signal: Math.max(0, Math.min(100, parseInt(f[2], 10) || 0)),
            security: security,
            secured: security !== "",
            enterprise: security.indexOf("802.1X") >= 0,
            active: f[0].trim() === "*"
        };
        const old = best[net.ssid];
        if (!old || (net.active && !old.active) || (net.active === old.active && net.signal > old.signal))
            best[net.ssid] = net;
    }
    const list = Object.keys(best).map(k => best[k]);
    list.sort((a, b) => (a.active === b.active ? b.signal - a.signal || (a.ssid < b.ssid ? -1 : 1) : a.active ? -1 : 1));
    return list;
}

// Names of the saved Wi-Fi profiles of `nmcli -t -f NAME,TYPE connection show`.
function parseWifiProfiles(text) {
    const out = [];
    for (const line of String(text).split("\n")) {
        const f = splitTerse(line);
        if (f.length >= 2 && f[1] === "802-11-wireless" && f[0] !== "")
            out.push(f[0]);
    }
    return out;
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

// What a click on a network does: "current" (already connected), "known" (saved profile), "open" (no password) or
// "password" (secured and new: the password flow lives in Quick Settings).
function wifiClickKind(net, profiles) {
    if (net.active)
        return "current";
    if (profiles.indexOf(net.ssid) >= 0)
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

function wifiConnectKnown(profile) {
    return plainName(profile) ? ["nmcli", "connection", "up", "id", profile] : null;
}

function wifiConnectOpen(ssid) {
    return plainName(ssid) ? ["nmcli", "device", "wifi", "connect", ssid] : null;
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
