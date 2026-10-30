.pragma library

// Quick Look windows (pure, unit-tested by tests/unit/tst_quicklook.qml). macOS: Quick Look belongs to the app that opened
// it: it gets no Dock tile, the menu bar keeps naming that app (the Finder), and the switcher does not list it. Grassfield's
// Quick Look is Glance, the panel of Preview (`grassfield-preview --glance`, Wayland app id org.grassfield.Preview.Glance,
// apps/preview/src/main.cpp): a window of its own, so every list of apps (Dock, switcher) skips it and the bar and the
// application's menus follow the window that was in front when it opened.

const IDS = ["org.grassfield.preview.glance"];

// True for the app id of a Quick Look window (case-insensitive, with or without a ".desktop" suffix).
function isQuickLook(appId) {
    const id = String(appId === undefined || appId === null ? "" : appId).replace(/\.desktop$/i, "").toLowerCase();
    return id !== "" && IDS.indexOf(id) >= 0;
}

// Who opened a quick look that now has the focus: the desktop when the desktop took the keyboard more recently than the last
// regular window got the focus (`desktopHeldAt`, `regularAt`: ms stamps, 0 = never), else that window. macOS: Quick Look from the
// desktop keeps the Finder's menus, from an app that app's. Stamps, not the state at the moment of the focus change: the
// desktop lets go of the keyboard and the quick look is focused in an order the compositor decides.
function openerIsDesktop(desktopHeldAt, regularAt) {
    return (desktopHeldAt || 0) > (regularAt || 0);
}
