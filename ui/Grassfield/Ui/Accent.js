.pragma library

// Accent colour (`accent.color`, docs/specs/ui.md "Accent colour"). Pure functions, no I/O: the palettes come from the
// `color.accentDark` / `color.accentLight` token groups, passed in as `tokens` (the Tokens singleton or any object with the
// same fields), so tests can check setting -> colours without a scene.

// "multicolor" is the default and keeps the Grassfield green of the `accent` / `accentText` roles; the others have their
// own light and dark values (roles `<name>` and `<name>Text` of the token groups). Order = order of the swatches.
const NAMES = ["multicolor", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"];

function validName(setting) {
    return typeof setting === "string" && NAMES.indexOf(setting) >= 0;
}

function normalize(setting) {
    return validName(setting) ? setting : "multicolor";
}

// {accent, accentText} for a setting in the dark or the light appearance, or null when the palette's own roles apply
// (multicolor, or anything invalid: a hand-edited value reads as the default).
function resolve(setting, dark, tokens) {
    const name = normalize(setting);
    if (name === "multicolor")
        return null;
    const group = dark ? tokens.colorAccentDark : tokens.colorAccentLight;
    return {accent: group[name], accentText: group[name + "Text"]};
}

// A copy of palette `base` with the accent applied. The highlight colour (text selection, Automatic) is the accent.
function apply(base, setting, dark, tokens) {
    const c = Object.assign({}, base);
    const a = resolve(setting, dark, tokens);
    if (a) {
        c.accent = a.accent;
        c.accentText = a.accentText;
    }
    return c;
}

// Selection: macOS draws white text on its accent fill in both appearances (a selected row, a default button, a checked box).
// The dark palette's accent is bright for glyphs, rings and indicators and holds 4.5:1 only with dark text, so a fill that
// carries text or a mark uses the light appearance's accent and its text colour in both appearances (ADR-0024 section 1;
// white on every light accent but yellow is 5.3:1 or more). `light` is the light palette with the same accent applied.
function withSelection(palette, light) {
    const c = Object.assign({}, palette);
    c.selection = light.accent;
    c.selectionText = light.accentText;
    return c;
}

// ---- Focus ring colour and Increase Contrast ----

// Channels (0..1) of a "#rrggbb" or "#aarrggbb" string; null for anything else.
function rgb(hex) {
    if (typeof hex !== "string" || !/^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(hex))
        return null;
    const h = hex.slice(-6);
    return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255];
}

function luminance(c) {
    const f = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
}

// WCAG 2.x contrast ratio of two "#rrggbb" colours; 1 when either is not one.
function contrast(a, b) {
    const ca = rgb(a);
    const cb = rgb(b);
    if (!ca || !cb)
        return 1;
    const la = luminance(ca);
    const lb = luminance(cb);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// The keyboard focus ring colour (one ring for every surface): the accent when it holds `minContrast` against the surface
// tint, else the text colour (the light appearance's yellow accent is 1.8:1 against its material; every other accent in both
// appearances passes), so the ring is a non-text element of 3:1 or more (WCAG 1.4.11) on every accent.
function focusRing(accent, tint, text, minContrast) {
    return contrast(accent, tint) >= minContrast ? accent : text;
}

// Increase Contrast (macOS Accessibility > Display): the secondary text colour is the primary one; the borders, separators and
// fills are drawn stronger by the tokens that carry an `increaseContrast` value.
function contrastBoost(palette, on) {
    if (!on)
        return palette;
    const c = Object.assign({}, palette);
    c.textSecondary = c.text;
    return c;
}
