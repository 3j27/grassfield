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
function effect(mode, tint, tokens) {
    const normalized = normalizeMode(mode);
    const result = {enabled: normalized !== "default", index: MODES.indexOf(normalized), tint: tint, mode: normalized};
    if (tokens !== undefined)
        Object.assign(result, legacyMultiEffect(normalized, tint, tokens));
    return result;
}

// The MultiEffect model the modes had before the shader (saturation, brightness, contrast, colorization, opacity). Nothing
// draws with it any more: FolderStyle's estimate of the engraved-symbol contrast still computes the mode's effect on a
// folder plate with this arithmetic (docs/specs/ui.md, "Icon shader": that estimate approximates the shader's result and
// is not re-measured against it).
function legacyMultiEffect(mode, tint, tokens) {
    switch (mode) {
    case "dark":
        return {saturation: tokens.iconModeDarkSaturation, brightness: tokens.iconModeDarkBrightness,
                contrast: tokens.iconModeDarkContrast, colorization: tokens.iconModeDarkColorization, colorizationColor: tokens.iconModeDarkShade, opacity: 1};
    case "clear":
        return {saturation: tokens.iconModeClearSaturation, brightness: tokens.iconModeClearBrightness,
                contrast: tokens.iconModeClearContrast, colorization: 0, colorizationColor: tint, opacity: tokens.iconModeClearOpacity};
    case "tinted":
        return {saturation: tokens.iconModeTintedSaturation, brightness: tokens.iconModeTintedBrightness,
                contrast: tokens.iconModeTintedContrast, colorization: tokens.iconModeTintedColorization, colorizationColor: tint, opacity: 1};
    }
    return {saturation: 0, brightness: 0, contrast: 0, colorization: 0, colorizationColor: tint, opacity: 1};
}

// One warning per process (an icon shader that cannot load fails for every icon).
let warned = false;
function warnOnce(message) {
    if (warned)
        return;
    warned = true;
    console.warn("grassfield-ui: " + message);
}
