.pragma library

// Pure logic of the adaptive menu bar foreground (docs/specs/menubar.md). The wallpaper strip under the bar of each output is
// reduced to one relative luminance (WCAG: linear, 0 black .. 1 white); the foreground is "light" (white text, over a dark
// wallpaper) or "dark" (black text, over a light one), with hysteresis so that a luminance hovering at the threshold does not flip it.

function linear(c) {
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

// Relative luminance of an sRGB colour, channels 0..1.
function luminance(r, g, b) {
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

// Mean relative luminance of RGBA bytes (0..255, as getImageData returns). Transparent pixels count as black.
function meanLuminance(bytes) {
    const n = Math.floor(bytes.length / 4);
    if (n <= 0)
        return 0;
    let sum = 0;
    for (let i = 0; i < n; i++) {
        const a = bytes[4 * i + 3] / 255;
        sum += a * luminance(bytes[4 * i] / 255, bytes[4 * i + 1] / 255, bytes[4 * i + 2] / 255);
    }
    return sum / n;
}

// WCAG contrast ratio of two relative luminances.
function contrastRatio(a, b) {
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

// Tone from the luminance distribution of the strip (ADR-0016 section 7): white text is limited by the lightest pixels
// of the strip (p95), black text by the darkest (p5). The tone with the better worst case wins; the previous tone stays
// unless the other is better by more than `margin` (no flip-flopping between two similar wallpapers). When even the best
// tone is below `needed` (4.5:1), `assist` is true: the bar shows the frosted band (macOS's "show menu bar background",
// switched on for that output) until the wallpaper changes.
// Returns {tone: "light" | "dark", white, black, best, assist}.
function stripTone(p5, p95, previous, needed, margin) {
    const hi = Math.max(0, Math.min(1, p95));
    const lo = Math.max(0, Math.min(1, p5));
    const white = contrastRatio(1, hi);
    const black = contrastRatio(0, lo);
    let tone = white >= black ? "light" : "dark";
    if ((previous === "light" || previous === "dark") && previous !== tone && Math.abs(white - black) < margin)
        tone = previous;
    const best = tone === "light" ? white : black;
    return {tone: tone, white: white, black: black, best: best, assist: Math.max(white, black) < needed};
}

// Luminance of a vertical two-stop gradient strip: from colour a (top) towards colour b, the strip covering the fraction
// `reach` (0..1) of the way; a and b are {r, g, b} in 0..1. The mean over the strip is taken at its middle.
function stripOfGradient(a, b, reach) {
    const t = Math.max(0, Math.min(1, reach)) / 2;
    return luminance(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t);
}

// "light" | "dark": the foreground for a luminance, given the previous one ("" when there is none).
// Dark needs lum > darkAbove, light needs lum < lightBelow; in between the previous choice stays (first time: the middle).
function decide(lum, previous, lightBelow, darkAbove) {
    if (lum > darkAbove)
        return "dark";
    if (lum < lightBelow)
        return "light";
    if (previous === "light" || previous === "dark")
        return previous;
    return lum > (lightBelow + darkAbove) / 2 ? "dark" : "light";
}

// New {name: tone} map after output `name` measured `lum`: only that output changes (a new object, so bindings re-evaluate).
function update(tones, name, lum, lightBelow, darkAbove) {
    const next = Object.assign({}, tones);
    next[name] = decide(lum, tones[name] || "", lightBelow, darkAbove);
    return next;
}

// ---- Dock running dot (the dot follows the appearance, the shelf tint is opaque enough per appearance: tests/unit/tst_bartone.qml) ----

// sRGB channel (0..1) of a linear value.
function encode(l) {
    return l <= 0.0031308 ? l * 12.92 : 1.055 * Math.pow(l, 1 / 2.4) - 0.055;
}

// Relative luminance of the Dock shelf: the material tint (`tint` {r, g, b} 0..1) at `alpha` over a wallpaper of relative
// luminance `wall` (taken as a grey), blended in sRGB like the compositor does. Without blur (`alpha` 1) it is the tint's own.
function shelfLuminance(wall, tint, alpha) {
    const g = encode(Math.max(0, Math.min(1, wall)));
    const a = Math.max(0, Math.min(1, alpha));
    return luminance(a * tint.r + (1 - a) * g, a * tint.g + (1 - a) * g, a * tint.b + (1 - a) * g);
}
