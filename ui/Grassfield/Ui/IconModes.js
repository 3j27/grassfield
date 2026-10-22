.pragma library

// Icon appearance modes (ADR-0014 phase 1, docs/specs/ui.md "Icon appearance modes"). Pure functions, no I/O, so tests
// can check mode -> effect without a scene. The numbers of each mode are the `iconMode` token group; IconEffect.qml
// hands them to the shader (shaders/icon.frag), which does the per-pixel work.

const MODES = ["default", "dark", "clear", "tinted"];

// "accent" (follow the accent colour) or a six-digit hex colour.
const TINT_PATTERN = /^#[0-9a-fA-F]{6}$/;

function normalizeMode(mode) {
    return MODES.indexOf(mode) >= 0 ? mode : "default";
}

function validTint(setting) {
    return setting === "accent" || (typeof setting === "string" && TINT_PATTERN.test(setting));
}

// The tint colour for a settings value: the hex colour, else (for "accent" or anything invalid) `accent`.
function tintColor(setting, accent) {
    return typeof setting === "string" && TINT_PATTERN.test(setting) ? setting : accent;
}

// The effect of a mode: `enabled` false means the icon is drawn as is (no effect item exists, so no extra render
// pass); `index` is the shader's mode (1 dark, 2 clear, 3 tinted, 0 none); `tint` only matters to "tinted".
function effect(mode, tint) {
    const normalized = normalizeMode(mode);
    return {enabled: normalized !== "default", index: MODES.indexOf(normalized), tint: tint, mode: normalized};
}

// One warning per process (an icon shader that cannot load fails for every icon).
let warned = false;
function warnOnce(message) {
    if (warned)
        return;
    warned = true;
    console.warn("grassfield-ui: " + message);
}
