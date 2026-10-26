.pragma library

// Adaptive glass (ADR-0024 section 2, points 1 to 4; G-1, G-2, G-3; owner decision 2026-10-26: the adaptive tint first).
// A surface class has a target tint (the clearer macOS 26 value at the default slider); the tint is raised to the
// smallest alpha that keeps its text at 4.5:1 over the backdrop: over the luminance range the shell measured when the
// output shows the bare desktop, else over any backdrop (black to white: the worst case of today's material). Pure
// functions, no I/O; tests/visual/test_contrast_tokens.py holds the same calculation for gate A2.

// Channels (0..1) of "#rrggbb"/"#aarrggbb" or of a QML color ({r, g, b}).
function channels(c) {
    if (typeof c === "string") {
        const h = c.slice(-6);
        return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255];
    }
    return [c.r, c.g, c.b];
}

function linear(v) {
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

function luminance(rgb) {
    return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2]);
}

// The sRGB grey (0..1) of a relative luminance.
function greyOf(lum) {
    const l = Math.max(0, Math.min(1, lum));
    return l <= 0.03928 / 12.92 ? l * 12.92 : 1.055 * Math.pow(l, 1 / 2.4) - 0.055;
}

function over(fg, alpha, bg) {
    return [fg[0] * alpha + bg[0] * (1 - alpha), fg[1] * alpha + bg[1] * (1 - alpha), fg[2] * alpha + bg[2] * (1 - alpha)];
}

function ratio(a, b) {
    const la = luminance(a);
    const lb = luminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// Backdrop colours of relative luminance `lum` that bound what the tint over them can become: the grey, and the vertices of
// the colours of that luminance in linear light (two channels at 0 or 1, the third solving the luminance), so a saturated
// backdrop (pure red is 0.21 like a mid grey, but blends much darker) is covered, not only its grey.
const WEIGHTS = [0.2126, 0.7152, 0.0722];

function backdropsOf(lum) {
    const l = Math.max(0, Math.min(1, lum));
    const g = greyOf(l);
    const out = [[g, g, g]];
    for (let c = 0; c < 3; c++) {
        const others = [0, 1, 2].filter(k => k !== c);
        for (let bits = 0; bits < 4; bits++) {
            const x = [0, 0, 0];
            x[others[0]] = bits & 1;
            x[others[1]] = (bits >> 1) & 1;
            const rest = l - WEIGHTS[others[0]] * x[others[0]] - WEIGHTS[others[1]] * x[others[1]];
            const free = rest / WEIGHTS[c];
            if (free < -1e-9 || free > 1 + 1e-9)
                continue;
            x[c] = Math.max(0, Math.min(1, free));
            out.push(x.map(greyOf));
        }
    }
    return out;
}

// The smallest tint alpha (steps of 0.01) that keeps every text colour at `need` over a backdrop of relative luminance
// lumMin and lumMax, with and without the fill overlay of a tile or field (fill at fillAlpha over the tint). Contrast moves
// monotonically with the backdrop's luminance between the two, so the two ends (each with its bounding colours) cover the
// range.
function floorAlpha(tint, texts, fill, fillAlpha, lumMin, lumMax, need) {
    const t = channels(tint);
    const f = channels(fill);
    const ink = texts.map(channels);
    const backs = backdropsOf(lumMin).concat(backdropsOf(lumMax));
    for (let i = 0; i <= 100; i++) {
        const a = i / 100;
        let ok = true;
        for (let b = 0; b < backs.length && ok; b++) {
            const base = over(t, a, backs[b]);
            const filled = over(f, fillAlpha, base);
            for (let k = 0; k < ink.length && ok; k++)
                ok = ratio(ink[k], base) >= need && ratio(ink[k], filled) >= need;
        }
        if (ok)
            return a;
    }
    return 1;
}

// The class tint at slider value t (0 = opaque, as Reduce Transparency; `defaultT` = the class target; 1 = clear): linear
// from 1 to the target up to the default, then from the target to 0 (G-2: the dead zone of the one-tint curve goes).
function targetAlpha(target, t, defaultT) {
    const x = Math.max(0, Math.min(1, t));
    if (x <= defaultT)
        return 1 - (1 - target) * x / defaultT;
    return target * (1 - (x - defaultT) / (1 - defaultT));
}

// The tint of a class: `backdrop` is {lumMin, lumMax} when the shell knows what lies behind the surface, null otherwise.
// `margin` is added to 4.5 over a measured backdrop (a picture's percentiles, the blur's own lift); none for the worst case,
// which is exact (black and white bound every backdrop).
function alpha(target, t, defaultT, backdrop, tint, texts, fill, fillAlpha, margin) {
    if (t <= 0)
        return 1;
    const known = backdrop !== null && backdrop !== undefined && typeof backdrop.lumMin === "number" && typeof backdrop.lumMax === "number";
    const floor = known ? floorAlpha(tint, texts, fill, fillAlpha, backdrop.lumMin, backdrop.lumMax, 4.5 + margin)
                        : floorAlpha(tint, texts, fill, fillAlpha, 0, 1, 4.5);
    return Math.max(floor, targetAlpha(target, t, defaultT));
}
