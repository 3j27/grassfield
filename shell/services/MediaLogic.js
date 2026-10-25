.pragma library

// Opening the app that plays (macOS: a click on the Now Playing artwork or title opens the app). Pure.
//
// windows: [{minimized}] of the player's app (matched by desktop entry id on the window's app id).
// Order: every window of the app is minimized -> bring the most recent one back (the player's Raise() does not
// restore a minimized window); else the player's own Raise() when it can raise; else the app's most recent
// window; else start the app from its desktop entry; "none" when nothing identifies the app.
function openPlan(canRaise, hasEntry, windows) {
    const list = Array.from(windows || []);
    if (list.length > 0 && list.every(w => w.minimized))
        return "activate";
    if (canRaise)
        return "raise";
    if (list.length > 0)
        return "activate";
    return hasEntry ? "launch" : "none";
}

// From an overlay panel (Quick Settings, the Now Playing popover) the focus is chosen by this click: closing the panel must
// not hand it back to the previous window (FocusReturn.skip, as a Dock menu item does). Only when the plan moves the focus.
function skipsFocusReturn(fromOverlay, plan) {
    return fromOverlay === true && (plan === "raise" || plan === "activate");
}

// Window app ids that belong to a desktop entry id ("org.foo.Bar.desktop" or "org.foo.Bar").
function appIdOf(desktopEntry) {
    return String(desktopEntry || "").replace(/\.desktop$/, "");
}
