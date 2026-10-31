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

// Who is in front, for the bar and the menus: "desktop" or "window" (the last regular window). A quick look belongs to whoever was in
// front when it opened (macOS: Quick Look from the desktop keeps the Finder's menus, from an app that app's). The state follows
// events, not time stamps:
//   desktopHeld      the desktop took the keyboard                                -> desktop
//   regularFocused   a regular window got the focus                              -> window
//   settled          a moment after the desktop let go of the keyboard: `focusedRegular` says whether the window with the focus
//                    is a regular one (the user clicked back into a window: Hyprland kept it active all along, so no focus
//                    change announces it) or not (a quick look or nothing took it: the desktop stays in front)
// A click on a quick look and a click on the window below look the same when the desktop lets go, hence the settle: the focus
// has landed by then.
function frontAfter(front, event) {
    switch (event.type) {
    case "desktopHeld":
        return "desktop";
    case "regularFocused":
        return "window";
    case "settled":
        return event.focusedRegular === true ? "window" : front;
    }
    return front;
}
