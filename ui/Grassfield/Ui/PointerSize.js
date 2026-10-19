.pragma library

// Pointer size (Settings > Accessibility > Pointer, ADR-0014). Pure functions, no I/O, shared by the Settings app
// (validation, slider mapping) and the shell (what it asks the compositor for).
// The value is a cursor size in pixels, the slider range of the macOS pointer size (Normal ... Large, 1x to 4x of the
// 24 px default). The hyprcursor theme is SVG (size independent), so Hyprland takes any size in the range.

const MIN = 24;
const MAX = 96;
const DEFAULT = 24;
// Slider step in pixels (19 positions from MIN to MAX).
const STEP = 4;

function valid(size) {
    return typeof size === "number" && isFinite(size) && Math.floor(size) === size && size >= MIN && size <= MAX;
}

// A stored value (any type) to a usable size: an invalid value is the default, nothing is clamped silently.
function normalize(size) {
    return valid(size) ? size : DEFAULT;
}

// A value read from grassfield.json (any JSON type) to the size the shell uses: a non-integer, a string or a number
// out of range is the default (nothing is rounded or clamped silently); a valid integer off the slider step snaps to it.
function fromStored(raw) {
    return valid(raw) ? snap(raw) : DEFAULT;
}

// A slider value to a storable size: rounded to the step, kept within the range.
function snap(value) {
    if (typeof value !== "number" || !isFinite(value))
        return DEFAULT;
    const stepped = MIN + Math.round((value - MIN) / STEP) * STEP;
    return Math.max(MIN, Math.min(MAX, stepped));
}

// `setcursor` request line for Hyprland's request socket, "" when the theme name is not a plain name or the size is
// invalid (the shell never forwards anything else to the compositor).
function setCursorRequest(theme, size) {
    if (typeof theme !== "string" || !/^[A-Za-z0-9_-]+$/.test(theme) || !valid(size))
        return "";
    return "/setcursor " + theme + " " + size;
}

// Environment that gives an application started by the shell the pointer size the user chose: XCURSOR_SIZE and
// HYPRCURSOR_SIZE, only when it differs from what the session environment already holds (`sessionSize`). {} otherwise.
function launchEnvironment(size, sessionSize) {
    if (!valid(size) || size === sessionSize)
        return {};
    return {"XCURSOR_SIZE": String(size), "HYPRCURSOR_SIZE": String(size)};
}

// Wait before attempt number `attempt` (1 for the first retry) of a lost request: base, then doubling.
function retryDelay(base, attempt) {
    return base * Math.pow(2, Math.max(0, attempt - 1));
}
