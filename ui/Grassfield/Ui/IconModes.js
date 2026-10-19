.pragma library

// Icon appearance modes (ADR-0014 phase 1, docs/specs/ui.md "Icon appearance modes"). Pure functions, no I/O: the
// numbers come from the `iconMode` token group, passed in as `tokens` (the Tokens singleton or any object with the
// same fields), so tests can check mode -> effect parameters without a scene.

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

// MultiEffect parameters of a mode. `enabled` false means the icon is drawn as is: no effect item exists, so no
// extra render pass. `tint` is only used by "tinted" (colorizationColor). "dark" darkens by colorizing towards black
// (every channel times 1 - colorization: hue kept; an additive brightness cut turns light icons blue); "clear" has no colorization.
function effect(mode, tint, tokens) {
    switch (normalizeMode(mode)) {
    case "dark":
        return {enabled: true, saturation: tokens.iconModeDarkSaturation, brightness: tokens.iconModeDarkBrightness,
                contrast: tokens.iconModeDarkContrast, colorization: tokens.iconModeDarkColorization, colorizationColor: tokens.iconModeDarkShade, opacity: 1};
    case "clear":
        return {enabled: true, saturation: tokens.iconModeClearSaturation, brightness: tokens.iconModeClearBrightness,
                contrast: tokens.iconModeClearContrast, colorization: 0, colorizationColor: tint, opacity: tokens.iconModeClearOpacity};
    case "tinted":
        return {enabled: true, saturation: tokens.iconModeTintedSaturation, brightness: tokens.iconModeTintedBrightness,
                contrast: tokens.iconModeTintedContrast, colorization: tokens.iconModeTintedColorization, colorizationColor: tint, opacity: 1};
    }
    return {enabled: false, saturation: 0, brightness: 0, contrast: 0, colorization: 0, colorizationColor: tint, opacity: 1};
}
