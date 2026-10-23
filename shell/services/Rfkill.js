.pragma library

// Pure logic of the rfkill soft block behind Airplane Mode (REQ-QS-CC3; unit-tested in tests/unit/tst_rfkill.qml).

// The radios Airplane Mode switches (macOS: Wi-Fi, Bluetooth, cellular), as `rfkill` type names.
const TYPES = ["wlan", "bluetooth", "wwan"];

// `rfkill --json list` output -> [{id, type, soft: bool, hard: bool}]. Both util-linux key spellings are accepted;
// anything unreadable gives an empty list.
function parseList(text) {
    let doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!doc || typeof doc !== "object")
        return [];
    let list = null;
    for (const k of Object.keys(doc)) {
        if (Array.isArray(doc[k])) {
            list = doc[k];
            break;
        }
    }
    if (!list)
        return [];
    return list.filter(d => d && typeof d.type === "string").map(d => ({
        id: d.id,
        type: d.type,
        soft: d.soft === "blocked",
        hard: d.hard === "blocked"
    }));
}

// Devices of the radios Airplane Mode governs.
function radios(devices) {
    return devices.filter(d => TYPES.indexOf(d.type) >= 0);
}

// {known, on}: known is false without any such radio (nothing to read); on when every one is blocked
// (a hardware-blocked radio is off whatever its soft state).
function airplane(devices) {
    const r = radios(devices);
    if (r.length === 0)
        return {known: false, on: false};
    return {known: true, on: r.every(d => d.soft || d.hard)};
}

// Command line that blocks or unblocks the radios (no root: /dev/rfkill is opened through the session's uaccess ACL).
function command(on) {
    return ["rfkill", on ? "block" : "unblock"].concat(TYPES);
}

// Why the soft block is not used, "" when it is. `exists`: /dev/rfkill is there; `writable`: this user may open it for
// reading and writing; `tool`: the rfkill program is installed.
function unavailableReason(exists, writable, tool) {
    if (!exists)
        return "missing";
    if (!tool)
        return "no-tool";
    if (!writable)
        return "not-writable";
    return "";
}
