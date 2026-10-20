.pragma library

// Returning the keyboard when a full-attention surface closes (docs/specs/overview.md "Close focus"): pure helpers shared
// by the Overview and every Exclusive shell surface (Search, Apps, the app switcher, the menus). Unit-tested
// (tests/unit/tst_focusreturn.qml).

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

// The user acted between the start of an attempt and its check: another window than the goal (and than the one active
// when the attempt started) is active now, or another Desktop than the goal (and than the one focused at the start) is
// focused. `before` is {address, workspace} recorded just before the attempt; the shell's own focus moves the active window
// to the goal only, so anything else is the user's (a click, a key bind, a window that opened).
function userActed(goal, before, active, focusedWorkspace) {
    if (!goal)
        return false;
    const was = before || {};
    if (goal.address)
        return !!active && !!active.address && active.address !== goal.address && active.address !== was.address;
    return focusedWorkspace > 0 && focusedWorkspace !== goal.workspace && focusedWorkspace !== was.workspace;
}

// What a check of the fallback does: "holds" (done), "surface" (an Exclusive surface opened: the keyboard is its),
// "user" (the user acted: their choice stands), "bound" (out of time: Hyprland's choice stands) or "retry".
function checkOutcome(goal, before, active, focusedWorkspace, elapsedMs, boundMs, surfaceOpen) {
    if (focusHolds(goal, active, focusedWorkspace))
        return "holds";
    if (surfaceOpen)
        return "surface";
    if (userActed(goal, before, active, focusedWorkspace))
        return "user";
    if (elapsedMs >= boundMs)
        return "bound";
    return "retry";
}

// The target a surface's close asks for: the window active when the surface opened, or null (nothing is requested: no
// window then, or another window was focused since by someone else, say a menu item that raised a window).
// `previous` is {address, workspaceId} or null, `active` the window active now.
function restoreTarget(previous, active) {
    if (!previous || !previous.address)
        return null;
    if (active && active.address && active.address !== previous.address)
        return null;
    const out = {kind: "remembered", address: previous.address};
    if (previous.workspaceId > 0)
        out.workspace = Math.floor(previous.workspaceId);
    return out;
}
