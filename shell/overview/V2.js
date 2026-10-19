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

// Keyboard plan of the chrome surfaces (v1 and v2). `screens` are the output names, `phase` "open" | "releasing" | "closed". Returns
// {screenName: "exclusive" | "none"}. While open every chrome is Exclusive: Hyprland sends pointer input to Exclusive
// layers only, so a None chrome would be dead to hover, click and drag. Hyprland gives the keyboard to ONE of the
// chromes (measured: not reliably the pointer's output) and the shell handles keys on any chrome. Every chrome is None
// when closed; the close then waits for every one to have committed (releaseDone) and focuses the remembered window
// itself (restorePlan).
// While releasing, `keep` (the output of the chrome that holds the keyboard, "" for none) stays Exclusive until every other
// chrome has committed None: the holder is released LAST, so that no Exclusive layer remains at the moment Hyprland
// refocuses (released first, its refocus is refused and never retried).
function keyboardPlan(screens, phase, keep) {
    const plan = {};
    for (const name of screens || [])
        plan[name] = phase === "open" || (phase === "releasing" && keep === name) ? "exclusive" : "none";
    return plan;
}

// Whether the chrome key handler may act: only while the overview is open and not releasing. During the release and
// once closed a key reaching a chrome is neither handled nor swallowed (it belongs to the window being refocused).
function keysEnabled(phase) {
    return phase === "open";
}

// Whether the keyboard release is complete and the close may proceed (action, plugin `on:false`, hide). Every output's
// chrome commits keyboard None on its own: Hyprland refuses to refocus ("refocusLastWindow: ignoring, exclusive LS
// present") while any of them is still Exclusive, and does not retry when the last one commits. So the close waits until
// no chrome reports the keyboard (`held` false) and the settle pause since the last change (`settled`) has elapsed;
// `forced` (the bound ran out) ends the wait whatever the reports say.
function releaseDone(held, settled, forced) {
    return forced === true || (!held && settled === true);
}

// What the close asks to be focused, one value for both modes (docs/specs/overview.md "Close focus"). `choice` is what
// the user did: null (no choice: Esc, toggle, IPC, backdrop), {kind: "window", address}, {kind: "space", id},
// {kind: "ended", workspace} (the plugin ended the overview itself, by a Desktop switch or the lock; `workspace` is the
// Desktop focused at that moment, 0 when unknown: the user's switch is kept, Hyprland's own refocus of the window active at
// open would undo it) or {kind: "other"} (another full-attention surface took the keyboard: nothing at all is requested).
// `previous` is {address, workspaceId} of the window that was active when the overview opened (null when none, or the
// desktop had the keyboard); `stayOnSpace` the id of a Desktop created with "+" while open (the shell switched to it:
// staying there is the choice).
// Returns {kind: "skip"} | {kind: "none"} | {kind: "window", address} | {kind: "workspace", workspace} |
// {kind: "remembered", address, workspace?}: the plugin's `overview_focus` targets, plus "skip".
function closeTarget(choice, previous, stayOnSpace) {
    if (choice && choice.kind === "other")
        return {kind: "skip"};
    if (choice && choice.kind === "ended")
        return choice.workspace > 0 ? {kind: "workspace", workspace: Math.floor(choice.workspace)} : {kind: "none"};
    if (choice && choice.kind === "window" && choice.address)
        return {kind: "window", address: choice.address};
    if (choice && choice.kind === "space" && choice.id > 0)
        return {kind: "workspace", workspace: Math.floor(choice.id)};
    if (stayOnSpace > 0)
        return {kind: "workspace", workspace: Math.floor(stayOnSpace)};
    if (previous && previous.address) {
        const out = {kind: "remembered", address: previous.address};
        if (previous.workspaceId > 0)
            out.workspace = Math.floor(previous.workspaceId);
        return out;
    }
    return {kind: "none"};
}

// Without the plugin capability (C2): what the shell focuses itself for a target. `live` are the addresses of the windows
// that exist now, `minimized` the addresses the shell has minimized (a minimized window never gets focus: it is not
// shown). Returns {kind: "window", address} | {kind: "space", id} | {kind: "none"} (Hyprland's own choice stands).
function fallbackPlan(target, live, minimized) {
    const exists = a => (live || []).indexOf(a) >= 0 && (minimized || []).indexOf(a) < 0;
    switch (target ? target.kind : "") {
    case "window":
    case "remembered":
        return exists(target.address) ? {kind: "window", address: target.address} : {kind: "none"};
    case "workspace":
        return {kind: "space", id: target.workspace};
    }
    return {kind: "none"};
}

// Whether the focus a fallback attempt asked for holds: `goal` is {address} (that window must be the active one) or
// {workspace} (that Desktop must be the focused one); `active` is {address, workspaceId} or null, `focusedWorkspace` the id.
function focusHolds(goal, active, focusedWorkspace) {
    if (!goal)
        return true;
    if (goal.address)
        return !!active && active.address === goal.address;
    return goal.workspace > 0 && focusedWorkspace === goal.workspace;
}

// Delay before the check after attempt `n` (0-based): the base doubles with each attempt, so a slow compositor gets a few
// quick retries and then fewer.
function retryDelay(n, base) {
    return base * Math.pow(2, Math.min(Math.max(n, 0), 6));
}

// ---- Selection across outputs ----

// The window an arrow key starts from when nothing is selected: the window that was active when the overview opened
// (macOS), wherever it is, else the first window of the first output that has one. `screens` is [{name, addresses}]
// in output order. Returns the address, "" for no window at all.
function startSelection(previous, screens) {
    const list = screens || [];
    if (previous && previous.address && list.some(s => s.addresses.indexOf(previous.address) >= 0))
        return previous.address;
    const first = list.find(s => s.addresses.length > 0);
    return first ? first.addresses[0] : "";
}

// The output an arrow key moves to when no window lies that way on the current one: the nearest output whose near edge
// is beyond this one's far edge, ties broken by the closest centre on the other axis. `screens` is
// [{name, x, y, w, h}] in layout coordinates, `dir` left | right | up | down. "" for none.
function adjacentScreen(screens, from, dir) {
    const cur = (screens || []).find(s => s.name === from);
    if (!cur)
        return "";
    const horizontal = dir === "left" || dir === "right";
    let best = "";
    let bestScore = Infinity;
    for (const s of screens) {
        if (s.name === from)
            continue;
        let gap;
        if (dir === "right")
            gap = s.x - (cur.x + cur.w);
        else if (dir === "left")
            gap = cur.x - (s.x + s.w);
        else if (dir === "down")
            gap = s.y - (cur.y + cur.h);
        else
            gap = cur.y - (s.y + s.h);
        if (gap < 0)
            continue;
        const across = horizontal ? Math.abs((s.y + s.h / 2) - (cur.y + cur.h / 2)) : Math.abs((s.x + s.w / 2) - (cur.x + cur.w / 2));
        const score = gap * 4 + across;
        if (score < bestScore) {
            best = s.name;
            bestScore = score;
        }
    }
    return best;
}

// The window an arrow key lands on when it enters an output from the side it left: `rects` is [{id, x, y, w, h}] in the
// output's own coordinates of size `area` {w, h}; `crossFrac` the position (0..1) along the other axis of the window it
// came from. Prefers the rectangle nearest that position, then the one nearest the entered edge. "" for none.
function entryWindow(rects, dir, crossFrac, area) {
    const horizontal = dir === "left" || dir === "right";
    let best = "";
    let bestScore = Infinity;
    for (const r of rects || []) {
        const cross = horizontal ? (r.y + r.h / 2) / area.h : (r.x + r.w / 2) / area.w;
        // Moving right arrives at the left edge, and so on.
        let edge;
        if (dir === "right")
            edge = r.x / area.w;
        else if (dir === "left")
            edge = 1 - (r.x + r.w) / area.w;
        else if (dir === "down")
            edge = r.y / area.h;
        else
            edge = 1 - (r.y + r.h) / area.h;
        const score = Math.abs(cross - crossFrac) * 2 + edge;
        if (score < bestScore) {
            best = r.id;
            bestScore = score;
        }
    }
    return best;
}
