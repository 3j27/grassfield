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
