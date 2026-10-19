.pragma library

// The front app of the Stages event (gfc/1 `stages`, docs/specs/stages.md "Event contract" 4), for the menu bar only.
// While an Exclusive layer holds the keyboard after a Stages swap Hyprland has no active window; the bar then names the
// front app of the shown Desktop (macOS: the frontmost app stays named behind a system modal). Pure, no compositor access.

// Plain text of at most this many characters (the plugin already sanitizes and caps at 256 bytes; this is untrusted
// text all the same).
const appMax = 128;
const unwanted = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069\\ufeff]", "g");

// Control characters (C0, DEL, C1), line/paragraph separators and bidi controls are dropped; the rest is kept as is.
function cleanApp(app) {
    if (typeof app !== "string")
        return "";
    const t = app.replace(unwanted, "").trim();
    return t.length > appMax ? t.slice(0, appMax) : t;
}

// Hex address without 0x, lower case; "" when it is not one.
function cleanAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

// Parses a `grassfield` raw event payload: {on, fronts: [{monitor, address, app}]} for a stages event, null for anything
// else (other types, foreign or malformed payloads). A monitor without a valid `front` contributes none.
function parse(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "stages")
        return null;
    const fronts = [];
    const mons = Array.isArray(msg.monitors) ? msg.monitors : [];
    for (let i = 0; i < mons.length; i++) {
        const m = mons[i];
        if (!m || !m.front || typeof m.monitor !== "string")
            continue;
        const address = cleanAddress(m.front.address);
        const app = cleanApp(m.front.app);
        if (address !== "" && app !== "")
            fronts.push({monitor: m.monitor, address: address, app: app});
    }
    return {on: msg.on === true, fronts: fronts};
}

// The front app to name, "" for none. `state`: last parse() result or null; `hasActiveWindow`: Hyprland reports an active
// window (it always wins); `pluginPresent`: the plugin is there (a gone plugin leaves no event worth trusting);
// `focusedMonitor`: name of the focused output ("" unknown: the first front is used); `liveAddresses`: addresses of the
// windows that exist now (a front window that closed names nothing).
function select(state, hasActiveWindow, pluginPresent, focusedMonitor, liveAddresses) {
    if (hasActiveWindow || !pluginPresent || !state || state.on !== true || state.fronts.length === 0)
        return "";
    let front = state.fronts.find(f => f.monitor === focusedMonitor);
    if (!front)
        front = state.fronts[0];
    const live = (liveAddresses || []).map(cleanAddress);
    return live.indexOf(front.address) >= 0 ? front.app : "";
}
