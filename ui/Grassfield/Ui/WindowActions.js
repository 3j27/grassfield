.pragma library

// What the window lights and the toolbar do to their window (ADR-0015). Pure functions over a QtQuick Window (or a
// stand-in with the same methods), unit-tested in tests/unit/tst_windowcontrols.qml. Every action is a plain xdg-toplevel
// request made by Qt (close, set_minimized, set_maximized / unset_maximized, set_fullscreen / unset_fullscreen,
// move): no compositor plugin is needed to send them, the plugin only completes minimize (ADR-0015, Q4).

// QWindow::Visibility.
const MAXIMIZED = 4;
const FULL_SCREEN = 5;

function isFullScreen(win) {
    return !!win && win.visibility === FULL_SCREEN;
}

function close(win) {
    if (win)
        win.close();
}

function minimize(win) {
    if (win)
        win.showMinimized();
}

// Zoom: the window fills the work area (menu bar and Dock stay), or goes back. With `fullScreen` (Option/Alt held)
// it is the true full screen instead, which a second request leaves.
//
// Hyprland toggles the maximized mode on any maximize request, whatever its value, and in the Grassfield session it
// sends the xdg "maximized" state to a floating window, so Qt believes a normal window is Maximized: showNormal() is then
// the request that reaches the compositor, and it toggles (spike step 4, ADR-0015). Where the compositor tracks the state
// honestly (no Grassfield session), the same branch sends set_maximized for a normal window. The decision therefore reads
// Qt's state only to choose the request, never to draw anything.
function zoom(win, fullScreen) {
    if (!win)
        return;
    if (fullScreen) {
        if (win.visibility === FULL_SCREEN)
            win.showNormal();
        else
            win.showFullScreen();
        return;
    }
    if (win.visibility === FULL_SCREEN || win.visibility === MAXIMIZED)
        win.showNormal();
    else
        win.showMaximized();
}

// A double-click on empty toolbar space does what `windows.titlebarDoubleClick` says: "zoom" (default), "minimize" or
// "none". Anything else counts as "zoom" (the default), as the plugin does. Returns what it did.
function doubleClick(win, action, canMinimize) {
    const what = action === "minimize" || action === "none" ? action : "zoom";
    if (what === "minimize") {
        if (canMinimize === false)
            return "none";
        minimize(win);
    } else if (what === "zoom") {
        zoom(win, false);
    }
    return what;
}

// The plugin's rule for a light's colour: coloured while the window is active or the pointer is over the lights,
// grey otherwise; a disabled light is always grey.
function lightIsGrey(active, groupHovered, enabled) {
    return !enabled || (!active && !groupHovered);
}

// Whether a light draws its glyph: all three show theirs while the pointer is over the group.
function glyphVisible(groupHovered, enabled) {
    return groupHovered && enabled;
}

// Which glyph the zoom light shows: "plus" normally, "arrows" while Option/Alt is held (the click then asks for true
// full screen; the lights are hidden once the window is in full screen).
function zoomGlyph(altHeld) {
    return altHeld ? "arrows" : "plus";
}

// Geometry of the three lights from the window's top-left corner, from the style's token values.
// style "unified": first centre at `unifiedCentre` on both axes; style "titlebar": first edge at `titlebarInset`, centred in
// `titlebarHeight`. Returns {x0, y0, pitch, width} where x0/y0 is the top-left of the first light.
function lightGeometry(style, tokens) {
    const d = tokens.diameter;
    const pitch = d + tokens.gap;
    const width = 3 * d + 2 * tokens.gap;
    if (style === "titlebar")
        return {x0: tokens.titlebarInset, y0: (tokens.titlebarHeight - d) / 2, pitch: pitch, width: width};
    return {x0: tokens.unifiedCentre - d / 2, y0: tokens.unifiedCentre - d / 2, pitch: pitch, width: width};
}

// The row height of a style.
function rowHeight(style, tokens) {
    return style === "titlebar" ? tokens.titlebarHeight : tokens.unifiedHeight;
}

// ADR-0015 Q4(b): minimize needs the compositor plugin (Hyprland does nothing on set_minimized), so an app greys its
// minimize light when the plugin is absent, as macOS greys an unavailable action. The shell writes its capabilities to one
// small file (apps/chromecaps.h holds the location and the same rule in C++). `text` is the file's content, "" when there is
// none. Only a readable file that says the plugin is absent, or lacks the "minimize" feature, greys the light; anything else
// is "not known" and leaves it enabled.
function minimizeAvailable(text) {
    let o = null;
    try {
        o = JSON.parse(text);
    } catch (e) {
        return true;
    }
    if (!o || typeof o !== "object" || o.v !== 1 || typeof o.pluginPresent !== "boolean")
        return true;
    if (!o.pluginPresent)
        return false;
    if (!Array.isArray(o.features))
        return true;
    return o.features.indexOf("minimize") >= 0;
}
