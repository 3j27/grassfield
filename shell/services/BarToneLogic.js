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
