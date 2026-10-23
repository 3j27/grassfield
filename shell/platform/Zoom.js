.pragma library

// Screen magnification (Settings > Accessibility > Zoom, GF-064; macOS: Accessibility > Zoom, Option-Command-8 toggles,
// Option-Command-= and - change the level). The compositor does it: Hyprland's `cursor:zoom_factor` magnifies the whole
// output around the pointer (1 = off). Pure functions, unit-tested; Zoom.qml sends the request.

const MIN = 1.5;
const MAX = 5;
const STEP = 0.5;
const DEFAULT = 2;

function clampLevel(level) {
    const n = Number(level);
    if (!isFinite(n))
        return DEFAULT;
    return Math.max(MIN, Math.min(MAX, Math.round(n / STEP) * STEP));
}

// The zoom factor the compositor should have: the level while zoom is on, else 1.
function factor(on, level) {
    return on === true ? clampLevel(level) : 1;
}

// One level in or out (direction +1 / -1), clamped, in steps of 0.5.
function step(level, direction) {
    return clampLevel(clampLevel(level) + (direction > 0 ? STEP : -STEP));
}

// Lua function for Hyprland's eval (Quickshell wraps it as `return hl.dispatch(<request>)`); `pcall` so that a Hyprland
// without the option does nothing instead of raising. "" for a factor that is not a number in [1, MAX].
function request(f) {
    const n = Number(f);
    if (!isFinite(n) || n < 1 || n > MAX)
        return "";
    return "function() pcall(hl.config, { cursor = { zoom_factor = " + n.toFixed(2) + " } }) end";
}
