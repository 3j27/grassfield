.pragma library

// Overview v2 (docs/specs/overview.md "Shell contract"): pure helpers, unit-tested. The real windows are transformed
// by grassfield-compositor; the shell only sends the layout and reacts to the plugin's `overview` events.

// Parses a `grassfield` raw event payload; the `overview` event as {state, windows, reason} or null.
// state: opening | open | closing | closed; reason: "" or one of the plugin's reasons.
var states = ["opening", "open", "closing", "closed"];
var reasons = ["invalid", "no-windows", "no-chrome", "unavailable", "interrupted", "fullscreen"];

function parseEvent(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "overview" || states.indexOf(msg.state) < 0)
        return null;
    const count = Number(msg.windows);
    return {
        state: msg.state,
        windows: Number.isFinite(count) && count >= 0 ? Math.floor(count) : 0,
        reason: typeof msg.reason === "string" && reasons.indexOf(msg.reason) >= 0 ? msg.reason : ""
    };
}

// What the shell does with an event, given whether its own overview is open. Returns
// {phase, fallback, close, retry}:
//   phase     plugin state to track: "idle" | "opening" | "open" | "closing" (unchanged when the event says nothing new)
//   fallback  thumbnails for this open (the request was refused, or the plugin is going away)
//   retry     no-chrome: the chrome may not have been Exclusive yet, try the request once more before falling back
//   close     the overview ended without the shell's on:false (interrupted): close the chrome
// A window that went full screen while shown (reason "fullscreen") also falls back: its workspace is drawn by Hyprland
// without transforming anything, so thumbnails are the way to show it.
function decide(phase, shellOpen, event) {
    const out = {phase: phase, fallback: false, retry: false, close: false};
    if (!event)
        return out;
    switch (event.reason) {
    case "invalid":
    case "no-windows":
    case "unavailable":
        out.fallback = shellOpen;
        out.phase = event.reason === "unavailable" || event.state === "closed" ? "idle" : phase;
        return out;
    case "no-chrome":
        out.retry = shellOpen;
        out.phase = "idle";
        return out;
    case "interrupted":
        out.close = shellOpen;
        out.phase = "idle";
        return out;
    case "fullscreen":
        out.fallback = shellOpen;
        return out;
    }
    switch (event.state) {
    case "opening":
        out.phase = shellOpen ? "opening" : phase;
        break;
    case "open":
        out.phase = shellOpen ? "open" : phase;
        break;
    case "closing":
        out.phase = "closing";
        break;
    case "closed":
        out.phase = "idle";
        break;
    }
    return out;
}

// Layout rectangle of a window as the Layout.js input: the surface box plus the titlebar band the plugin draws above
// it (`band` px), both in coordinates relative to the free area's origin.
function layoutInput(address, x, y, w, h, band) {
    return {id: address, x: x, y: y - band, w: w, h: h + band};
}

// Surface box (what the plugin is asked to draw, layout coordinates) from the layout rect of the surface + titlebar
// band: the scale is uniform, so the band is `band * scale` px; `screenX/screenY` is the output origin, `offsetY` the
// distance of the chrome surface's top from the output's top (the menu bar).
function surfaceRect(rect, realWidth, band, screenX, screenY, offsetY) {
    const s = realWidth > 0 ? rect.w / realWidth : 1;
    const top = band * s;
    return {x: screenX + rect.x, y: screenY + offsetY + rect.y + top, w: rect.w, h: Math.max(1, rect.h - top)};
}

// Keyboard plan of the chrome surfaces (v1 and v2). `screens` are the output names, `keyScreen` the output chosen when
// opening ("" or unknown: the first one), `phase` "open" | "releasing" | "closed". Returns {screenName: "exclusive" |
// "none"}. Exactly one chrome is Exclusive while open (a second Exclusive surface would receive the keyboard when the
// first goes away, and Hyprland's refocusLastWindow ignores the close while any exclusive layer is present); every
// chrome is None while releasing (before the close completes) and when closed, so Hyprland refocuses the last window.
// The other outputs' chromes keep their input region (clicks still map), only the keyboard differs.
function keyboardPlan(screens, keyScreen, phase) {
    const plan = {};
    const list = screens || [];
    const holder = list.indexOf(keyScreen) >= 0 ? keyScreen : (list.length > 0 ? list[0] : "");
    for (const name of list)
        plan[name] = phase === "open" && name === holder ? "exclusive" : "none";
    return plan;
}
