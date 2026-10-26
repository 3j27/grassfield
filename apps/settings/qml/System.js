.pragma library

// Pure logic of the system sections (Wi-Fi, Bluetooth, Sound, Displays): parsers of the backends' answers, the actions as
// the Backend takes them, display arrangement. No I/O here.
//   Wi-Fi and Bluetooth: NetworkManager and BlueZ over D-Bus (src/systembus.h); the Backend answers with a JSON state
//   (Backend.busQuery) and takes actions as {op: ...} maps (Backend.busAct).
//   Sound: `wpctl` (PipeWire and WirePlumber have no D-Bus interface): its read-only query and its action programs must stay
//   in step with apps/settings/src/systemguard.cpp: tests/shell/settings_system_guard.sh runs every QUERY entry through the real
//   guard and fails if one is refused. wpctl runs in the C locale (Backend forces LC_ALL=C): the parser reads the English output.

// ---- Read-only queries ---------------------------------------------------------------------------------------------

// The only command-line query of the system sections (the Sound page); Wi-Fi and Bluetooth are read over D-Bus (SystemService.queryBus).
var QUERY = {
    audio: ["wpctl", "status"]
};

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

// ---- Wi-Fi (NetworkManager over D-Bus) -----------------------------------------------------------------------------

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

// NetworkManager's access point flags as the label nmcli printed (the old SECURITY column): "" for an open network, else
// "WPA3", "WPA2", "WPA1", "802.1X", "OWE" (Enhanced Open: no password), "WEP", joined by spaces. `flags` is the AP's Flags (bit 0: privacy), `wpa` and
// `rsn` its WpaFlags and RsnFlags (key management bits 0x100 PSK, 0x200 802.1X, 0x400 SAE, 0x800 OWE).
function wifiSecurity(flags, wpa, rsn) {
    const out = [];
    if (rsn & 0x400)
        out.push("WPA3");
    if (rsn & 0x100)
        out.push("WPA2");
    if (wpa & 0x100)
        out.push("WPA1");
    if ((rsn | wpa) & 0x200)
        out.push("802.1X");
    if (rsn & 0x800)
        out.push("OWE");
    // 0x1000: OWE transition, an open network that also has an Enhanced Open twin: no credentials, still open (as systembus.cpp).
    if (out.length === 0 && (wpa !== 0 || (rsn & ~0x1000) !== 0))
        out.push("WPA");
    if (out.length === 0 && (flags & 1) && rsn === 0 && wpa === 0)
        out.push("WEP");
    return out.join(" ");
}

// The `wifi.state` JSON of the Backend (src/systembus.h wifiState): {radio, device: {name, connected} | null, networks,
// profiles: {SSID hex: UUID of the first saved profile with that SSID}}; null when the text is not that. `networks` are the
// visible networks, one per SSID and security (the strongest access point; the connected one wins), connected first, then by
// signal, as flat objects with the stable id `key` (SSID bytes + security): {key, hex, ssid, label, strength (0-100),
// security, secured, enterprise, active, valid (the name can be passed on as it is)}. Hidden networks (empty SSID) are skipped.
function parseWifiState(text) {
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (j === null || typeof j !== "object" || typeof j.radio !== "boolean" || !Array.isArray(j.aps) || !Array.isArray(j.profiles))
        return null;
    const best = {};
    for (const ap of j.aps) {
        if (ap === null || typeof ap !== "object" || typeof ap.hex !== "string" || ap.hex.trim() === "")
            continue;
        const name = hexToText(ap.hex);
        if (name.text === "")
            continue;
        const security = wifiSecurity(ap.flags | 0, ap.wpa | 0, ap.rsn | 0);
        const hex = ap.hex.trim().toUpperCase();
        const net = {
            key: hex + "|" + security,
            hex: hex,
            ssid: name.text,
            label: printable(name.text),
            strength: Math.max(0, Math.min(100, ap.strength | 0)),
            security: security,
            secured: security !== "" && security !== "OWE", // Enhanced Open joins without a password, like an open network
            enterprise: security.indexOf("802.1X") >= 0,
            active: ap.active === true,
            valid: name.valid && plainName(name.text)
        };
        const old = best[net.key];
        if (!old || (net.active && !old.active) || (net.active === old.active && net.strength > old.strength))
            best[net.key] = net;
    }
    const networks = Object.keys(best).map(k => best[k]);
    networks.sort((a, b) => (a.active === b.active ? b.strength - a.strength || (a.key < b.key ? -1 : 1) : a.active ? -1 : 1));
    const known = {};
    for (const p of j.profiles) {
        if (p !== null && typeof p === "object" && validUuid(p.uuid) && typeof p.hex === "string" && p.hex !== "") {
            const hex = p.hex.toUpperCase();
            if (known[hex] === undefined)
                known[hex] = p.uuid;
        }
    }
    const device = j.device !== null && typeof j.device === "object" && typeof j.device.name === "string" ? {name: j.device.name, connected: j.device.connected === true} : null;
    return {radio: j.radio, device: device, networks: networks, known: known};
}

// Signal glyph of the shell's icon set for a 0-100 strength.
function wifiGlyph(signal) {
    return signal >= 67 ? "wifi-3" : signal >= 34 ? "wifi-2" : "wifi-1";
}

// What a click on a network does; `known` maps the SSID hex of each saved profile to its UUID.
// "current" (already connected), "known" (saved profile with that SSID), "open" (no password), "password" (WPA/WPA3
// personal: the page asks for the passphrase), "account" (802.1X only: a sign-in Settings does not set up) or "unsupported"
// (WEP).
function wifiClickKind(net, known) {
    if (net.active)
        return "current";
    if (known[net.hex] !== undefined)
        return "known";
    if (!net.secured)
        return "open";
    return /WPA/.test(net.security) ? "password" : net.enterprise ? "account" : "unsupported";
}

// The two lists of the pane (macOS 27): Known Network (the networks in range with a saved profile, the current one first)
// and Other Networks (the rest, strongest first). `networks` as parseWifiState gives them.
function wifiSections(networks, known) {
    const out = {known: [], other: []};
    for (const n of networks)
        (n.active || known[n.hex] !== undefined ? out.known : out.other).push(n);
    return out;
}

// A WPA/WPA3 personal passphrase as NetworkManager takes it (src/systembus.cpp isPassphrase): 8 to 63 printable ASCII
// characters, or 64 hex digits.
function validPassphrase(psk) {
    return typeof psk === "string" && (/^[\x20-\x7E]{8,63}$/.test(psk) || /^[0-9A-Fa-f]{64}$/.test(psk));
}

// Wi-Fi band of a frequency in MHz ("2.4 GHz", "5 GHz", "6 GHz"); "" when unknown.
function wifiBand(mhz) {
    const f = Number(mhz);
    return f >= 5925 ? "6 GHz" : f >= 4900 ? "5 GHz" : f >= 2400 ? "2.4 GHz" : "";
}

// IPv4 subnet mask of a prefix length (24 -> "255.255.255.0"); "" when out of range.
function subnetMask(prefix) {
    const n = Number(prefix);
    if (!Number.isInteger(n) || n < 0 || n > 32)
        return "";
    const parts = [];
    for (let i = 0; i < 4; i++) {
        const bits = Math.max(0, Math.min(8, n - 8 * i));
        parts.push(256 - Math.pow(2, 8 - bits));
    }
    return parts.join(".");
}

// The `net.state` JSON of the Backend (src/systembus.h networkState): {devices, vpns} with only well-formed entries (strings
// where strings are due, lists of strings, the states the Backend gives); null when the text is not that.
function parseNetState(text) {
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (j === null || typeof j !== "object" || !Array.isArray(j.devices) || !Array.isArray(j.vpns))
        return null;
    const str = v => (typeof v === "string" ? printable(v) : "");
    const strs = v => (Array.isArray(v) ? v.filter(x => typeof x === "string" && x !== "").map(printable) : []);
    const states = ["connected", "connecting", "disconnected", "unavailable"];
    const devices = [];
    for (const d of j.devices) {
        if (d === null || typeof d !== "object" || (d.type !== "ethernet" && d.type !== "wifi") || typeof d.name !== "string" || d.name === "")
            continue;
        devices.push({
            name: printable(d.name), type: d.type, state: states.indexOf(d.state) >= 0 ? d.state : "unavailable", mac: str(d.mac),
            connection: str(d.connection), uuid: validUuid(d.uuid) ? d.uuid : "", ip4: strs(d.ip4), router: str(d.router), dns: strs(d.dns),
            ip6: strs(d.ip6), router6: str(d.router6), bitrate: Number(d.bitrate) > 0 ? Number(d.bitrate) : 0,
            frequency: Number(d.frequency) > 0 ? Number(d.frequency) : 0, ssid: typeof d.ssid === "string" ? hexToText(d.ssid).text : ""
        });
    }
    const vpns = [];
    for (const v of j.vpns) {
        if (v !== null && typeof v === "object" && validUuid(v.uuid) && typeof v.name === "string")
            vpns.push({uuid: v.uuid, name: printable(v.name !== "" ? v.name : v.uuid), kind: v.kind === "wireguard" ? "wireguard" : "vpn",
                       state: states.indexOf(v.state) >= 0 ? v.state : "disconnected"});
    }
    vpns.sort((a, b) => (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0));
    return {devices: devices, vpns: vpns};
}

// ---- Bluetooth (BlueZ over D-Bus) ----------------------------------------------------------------------------------

// The `bt.state` JSON of the Backend (src/systembus.h bluetoothState): {present, powered, devices: [{mac, name, connected}]}
// with the paired devices connected first, then by name; null when the text is not that.
function parseBtState(text) {
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (j === null || typeof j !== "object" || typeof j.present !== "boolean" || typeof j.powered !== "boolean" || !Array.isArray(j.devices))
        return null;
    const list = [];
    for (const d of j.devices) {
        if (d !== null && typeof d === "object" && typeof d.mac === "string" && /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/.test(d.mac))
            list.push({mac: d.mac.toUpperCase(), name: typeof d.name === "string" && d.name.trim() !== "" ? printable(d.name.trim()) : d.mac.toUpperCase(), connected: d.connected === true});
    }
    list.sort((a, b) => (a.connected === b.connected ? (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1) : a.connected ? -1 : 1));
    return {present: j.present, powered: j.present && j.powered, devices: list};
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

// ---- Actions (wpctl argument vectors and D-Bus action maps; null for anything invalid, so a bad value never reaches a process) ----

function plainName(s) {
    return typeof s === "string" && s !== "" && s.length <= 255 && s[0] !== "-" && !/[\x00-\x1f]/.test(s);
}

// Wi-Fi and Bluetooth actions are maps the Backend takes (Backend.busAct, validated again in src/systembus.cpp).
function wifiRadio(on) {
    return {op: "wifi.radio", on: on === true};
}

function wifiConnectKnown(uuid) {
    return validUuid(uuid) ? {op: "wifi.connectKnown", uuid: uuid} : null;
}

// An open network by its (clean, at most 32 bytes) name.
function wifiConnectOpen(ssid) {
    if (!plainName(ssid) || ssid.indexOf("\uFFFD") >= 0)
        return null;
    const hex = textToHex(ssid);
    return hex.length <= 64 ? {op: "wifi.connectOpen", hex: hex} : null;
}

// A WPA/WPA3 personal network by its (clean, at most 32 bytes) name, with its passphrase.
function wifiConnectSecure(ssid, psk) {
    if (!plainName(ssid) || ssid.indexOf("\uFFFD") >= 0 || !validPassphrase(psk))
        return null;
    const hex = textToHex(ssid);
    return hex.length <= 64 ? {op: "wifi.connectSecure", hex: hex, psk: psk} : null;
}

// Forget This Network: the saved profile with that UUID.
function wifiForget(uuid) {
    return validUuid(uuid) ? {op: "wifi.forget", uuid: uuid} : null;
}

// A VPN or WireGuard profile switched on or off.
function vpnConnect(uuid, on) {
    return validUuid(uuid) ? {op: "vpn.connect", uuid: uuid, on: on === true} : null;
}

// Disconnect the Wi-Fi device (the Backend takes the first Wi-Fi device; `device` is the one the page knows, a valid name).
function wifiDisconnect(device) {
    return typeof device === "string" && /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$/.test(device) ? {op: "wifi.disconnect"} : null;
}

function wifiScan() {
    return {op: "wifi.scan"};
}

function btPower(on) {
    return {op: "bt.power", on: on === true};
}

function btConnect(mac, connect) {
    return typeof mac === "string" && /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/.test(mac) ? {op: "bt.connect", mac: mac.toUpperCase(), connect: connect === true} : null;
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
