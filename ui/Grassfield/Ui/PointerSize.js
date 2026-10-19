.pragma library

// Pointer size (Settings > Accessibility > Pointer, ADR-0014). Pure functions, no I/O, shared by the Settings app
// (validation, slider mapping) and the shell (what it asks the compositor for).
// The value is a cursor size in pixels, the slider range of the macOS pointer size (Normal ... Large, 1x to 4x of the
// 24 px default). The hyprcursor theme is SVG (size independent), so Hyprland takes any size in the range; the XCursor
// fallback (XWayland, GTK, Qt) is rendered at fixed sizes and uses the nearest one.

const MIN = 24;
const MAX = 96;
const DEFAULT = 24;
// Slider step in pixels (19 positions from MIN to MAX).
const STEP = 4;
// Sizes built into the XCursor fallback by branding/cursors/build.sh.
const XCURSOR_SIZES = [24, 32, 48, 64, 96];

function valid(size) {
    return typeof size === "number" && isFinite(size) && Math.floor(size) === size && size >= MIN && size <= MAX;
}

// A stored value (any type) to a usable size: an invalid value is the default, nothing is clamped silently.
function normalize(size) {
    return valid(size) ? size : DEFAULT;
}

// A slider value to a storable size: rounded to the step, kept within the range.
function snap(value) {
    if (typeof value !== "number" || !isFinite(value))
        return DEFAULT;
    const stepped = MIN + Math.round((value - MIN) / STEP) * STEP;
    return Math.max(MIN, Math.min(MAX, stepped));
}

// Nearest XCursor size (the smaller one on a tie, so 40 is 32 and 56 is 48).
function xcursorSize(size) {
    const s = normalize(size);
    let best = XCURSOR_SIZES[0];
    for (const candidate of XCURSOR_SIZES) {
        if (Math.abs(candidate - s) < Math.abs(best - s))
            best = candidate;
    }
    return best;
}

// `setcursor` request line for Hyprland's request socket, "" when the theme name is not a plain name or the size is
// invalid (the shell never forwards anything else to the compositor).
function setCursorRequest(theme, size) {
    if (typeof theme !== "string" || !/^[A-Za-z0-9_-]+$/.test(theme) || !valid(size))
        return "";
    return "/setcursor " + theme + " " + size;
}
