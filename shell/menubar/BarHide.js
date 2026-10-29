.pragma library

// Menu bar auto-hide policy (pure, unit-tested by tests/unit/tst_barhide.qml). The state machine itself (shown, hiding, hidden,
// revealing, dwell at the edge) is the Dock's shell/dock/AutoHide.js; this file only answers what the setting means.
//
// Setting "Automatically hide and show the menu bar" (macOS names), key `menubar.autoHide`:
//   always      hidden on the desktop and in full screen
//   desktop     hidden on the desktop only ("On Desktop Only"), shown over full-screen windows
//   fullscreen  hidden in full screen only ("In Full Screen Only", the default)
//   never       always shown, over full-screen windows too

const MODES = ["always", "desktop", "fullscreen", "never"];
const DEFAULT_MODE = "fullscreen";

function normalize(mode) {
    return MODES.indexOf(mode) >= 0 ? mode : DEFAULT_MODE;
}

// True when the bar slides away (and a pointer at the top edge brings it back) for this mode on an output whose current
// workspace has (`fullscreen`) or has not a full-screen window.
function hides(mode, fullscreen) {
    switch (normalize(mode)) {
    case "always":
        return true;
    case "desktop":
        return !fullscreen;
    case "fullscreen":
        return !!fullscreen;
    }
    return false;
}

// Whether the bar keeps its exclusive zone. Only a bar that is on the desktop in its mode reserves space, and the
// reservation never changes with reveal or hide (no window reflows): `fullscreen` and `never` reserve, `always` and
// `desktop` do not (a maximized window then sits under the bar while it is revealed, like macOS).
function reservesSpace(mode) {
    const m = normalize(mode);
    return m === "fullscreen" || m === "never";
}

// Whether the wallpaper strip under the bar is what the band lies on: the bar reserves space (no window under it) and no
// full-screen window is on its output. With `always` or `desktop` a maximized window sits under a revealed bar, and over a
// full-screen window the bar is drawn on that window's content: the wallpaper's strip says nothing then.
function bandOnWallpaper(mode, fullscreen) {
    return reservesSpace(mode) && !fullscreen;
}

// The bar sits on the overlay layer (above Hyprland's full-screen windows; the top layer is below them) while a full-screen
// window is on its output, the top layer otherwise.
function overlayLayer(fullscreen) {
    return !!fullscreen;
}

// Height of the part of the bar window that takes input: the whole bar while it is (coming) in view, only the edge strip
// while it is away.
function inputHeight(barHeight, revealZone, away) {
    return away ? Math.min(barHeight, revealZone) : barHeight;
}

// Vertical offset of the bar content for a slide position `visible` (0 hidden, 1 shown, already eased).
function slideOffset(barHeight, visible) {
    return -barHeight * (1 - Math.min(1, Math.max(0, visible)));
}
