.pragma library

// Minimized-window bookkeeping (pure, unit-tested). The shell records every window it
// minimized: Hyprland has no minimized state, so the record is the source of truth for the Dock.
// Record: {toplevel, address, appId, title}.

// Validated lowercase hex of a Hyprland window address ("0x" prefix optional), "" if invalid.
function normalizeAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

function has(list, toplevel) {
    return list.some(r => r.toplevel === toplevel);
}

// New list with the record appended (a window is recorded once).
function add(list, record) {
    return has(list, record.toplevel) ? list : list.concat([record]);
}

function remove(list, toplevel) {
    return list.filter(r => r.toplevel !== toplevel);
}

// Drops records whose window no longer exists. `live` is an array of toplevel handles.
function prune(list, live) {
    return list.filter(r => live.indexOf(r.toplevel) >= 0);
}

// Windows of an app (case-insensitive app id) that are minimized.
function forApp(list, appId) {
    const wanted = String(appId).toLowerCase();
    return list.filter(r => String(r.appId).toLowerCase() === wanted);
}

// Parses a `grassfield` raw event payload; returns the validated address of a minimize-request, or "".
function minimizeRequestAddress(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return "";
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "minimize-request" || typeof msg.address !== "string")
        return "";
    return normalizeAddress(msg.address);
}
