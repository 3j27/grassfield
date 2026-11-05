.pragma library

// Wi-Fi > Details > Share Network… (ADR-0045 OC-10): the answer of Omarchy's `omarchy-network-qr --meta` (v4.0.6), read as
// it prints it, the code drawn by ShareNetworkSheet.qml. Its output:
//   meta <TAB> <interface> <TAB> <security: WPA | WEP | nopass> <TAB> <SSID: the rest of the line, tabs included>
//   then one line per row of modules, one character per module, "1" dark and "0" light; qrencode's 4-module quiet zone is
//   part of the matrix (Omarchy collapses each two-character ASCII module of `qrencode --type ASCII --margin 4` to one).
// The payload itself (WIFI:T:...;S:...;P:...;;) never reaches Settings: only the matrix, which encodes it, and the name.

// QR versions 1 to 40 are 21 to 177 modules wide; with the quiet zone 29 to 185.
const MIN_SIZE = 29;
const MAX_SIZE = 185;

// {iface, security, ssid, size, rows: ["0101...", ...]}; null when the text is not that (no meta line, rows of different
// lengths, a matrix that is not square, a character other than 0 and 1, a size no QR code has).
function parse(text) {
    const lines = String(text || "").split("\n").map(l => l.replace(/\r$/, ""));
    while (lines.length > 0 && lines[lines.length - 1] === "")
        lines.pop();
    if (lines.length < 2)
        return null;
    const meta = lines[0].split("\t");
    if (meta.length < 4 || meta[0] !== "meta")
        return null;
    const security = meta[2];
    if (["WPA", "WEP", "nopass"].indexOf(security) < 0)
        return null;
    const rows = lines.slice(1);
    const size = rows[0].length;
    if (size < MIN_SIZE || size > MAX_SIZE || rows.length !== size)
        return null;
    for (const r of rows) {
        if (r.length !== size || !/^[01]+$/.test(r))
            return null;
    }
    return {iface: meta[1], security: security, ssid: meta.slice(3).join("\t"), size: size, rows: rows};
}

// Whether a parsed code is the network the Details sheet shows (Omarchy picks the device itself: the default route's, else
// the first connected Wi-Fi device).
function matches(code, ssid) {
    return code !== null && code !== undefined && code.ssid === String(ssid || "");
}

// The dark modules as runs on each row, [{x, y, w}], so a row of dark modules is one rectangle.
function runs(code) {
    const out = [];
    if (!code)
        return out;
    for (let y = 0; y < code.rows.length; y++) {
        const r = code.rows[y];
        let x = 0;
        while (x < r.length) {
            if (r[x] !== "1") {
                x++;
                continue;
            }
            const from = x;
            while (x < r.length && r[x] === "1")
                x++;
            out.push({x: from, y: y, w: x - from});
        }
    }
    return out;
}
