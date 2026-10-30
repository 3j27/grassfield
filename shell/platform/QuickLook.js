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
