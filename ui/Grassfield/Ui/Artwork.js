.pragma library

// The four Grassfield artworks (ADR-0040 step 2, ID-1): palettes from the `artwork.*` tokens and the procedural geometry of
// Meadow and Field Rows. Pure functions, used by GrassfieldArtwork.qml and the tests; deterministic (seeded), so a picture is
// the same at every start and on every output.

const ARTWORKS = ["grassfield", "meadow", "rows", "ridgeline"];
const PHASES = ["dawn", "day", "evening", "night"];
// The variant every caller gets without asking (the lock and the screen saver until step 4a): the artwork as it was.
const DEFAULT_VARIANT = "evening.dark";

function cap(s) {
    return s.charAt(0).toUpperCase() + s.substring(1);
}

// {artwork, phase, set}: a known artwork and variant; anything else reads as the Grassfield evening in the dark set.
function parse(artwork, variant) {
    const a = ARTWORKS.indexOf(artwork) >= 0 ? artwork : "grassfield";
    const v = typeof variant === "string" ? variant : "";
    if (a === "grassfield") {
        const p = v.split(".");
        if (p.length === 2 && PHASES.indexOf(p[0]) >= 0 && (p[1] === "light" || p[1] === "dark"))
            return {artwork: a, phase: p[0], set: p[1]};
        return {artwork: a, phase: "evening", set: "dark"};
    }
    return {artwork: a, phase: "", set: v === "light" ? "light" : "dark"};
}

// The palette of an artwork's variant from the tokens: {artwork, phase, set, sky, sun, sunAt, hills, blades, bands, tone, colours}.
// `tone` is the top of the picture as the menu bar's tone reads it: from colour `top` towards `next`, which sits at the fraction
// `at` of the height. `colours`: every colour drawn (the glass backdrop's range, ADR-0024).
function palette(T, artwork, variant) {
    const v = parse(artwork, variant);
    const S = cap(v.set);
    const out = {artwork: v.artwork, phase: v.phase, set: v.set, sky: [], sun: "", sunAt: [0, 0, 0], hills: [], blades: [], bands: [], glow: null, bladeAlphas: []};
    if (v.artwork === "grassfield") {
        const key = "artworkGrassfield" + cap(v.phase) + S;
        out.sky = T[key + "Sky"];
        out.sun = T[key + "Sun"];
        out.sunAt = T[key + "SunAt"];
        out.hills = T[key + "Hills"];
        out.tone = {top: out.sky[0], next: out.sky[1], at: 0.55};
        out.stops = [[0, out.sky[0]], [0.55, out.sky[1]], [0.78, out.sky[2]]];
        out.glow = {x: out.sunAt[0], y: out.sunAt[1], r: out.sunAt[2], alphas: [[0, 1], [0.35, 0.55], [1, 0]]};
        out.colours = out.sky.concat([out.sun], out.hills);
    } else if (v.artwork === "meadow") {
        out.sky = T["artworkMeadow" + S + "Sky"];
        out.blades = T["artworkMeadow" + S + "Blades"];
        out.tone = {top: out.sky[0], next: out.sky[1], at: 1};
        out.stops = [[0, out.sky[0]], [1, out.sky[1]], [1, out.sky[1]]];
        out.bladeAlphas = [0.55, 0.7, 0.85, 1];
        out.colours = out.sky.concat(out.blades);
    } else if (v.artwork === "rows") {
        out.bands = T["artworkRows" + S];
        // The top strip crosses the first bands (rowsBands: band 2's curve starts at the top edge).
        out.tone = {top: out.bands[1], next: out.bands[2], at: 1};
        out.stops = [[0, out.bands[0]], [1, out.bands[0]], [1, out.bands[0]]];
        out.colours = out.bands.slice();
    } else {
        out.sky = T["artworkRidgeline" + S + "Sky"];
        out.hills = T["artworkRidgeline" + S + "Hills"];
        out.sun = T["artworkRidgeline" + S + "Sun"];
        out.tone = {top: out.sky[0], next: out.sky[1], at: 0.6};
        out.stops = [[0, out.sky[0]], [0.6, out.sky[1]], [1, out.sky[2]]];
        out.glow = {x: 0.5, y: 0.78, r: 0.45, alphas: [[0, 0.9], [1, 0], [1, 0]]};
        out.colours = out.sky.concat(out.hills, [out.sun]);
    }
    return out;
}

// The flat colour map callers read (`art`): skyTop and skyMid are the tone's two colours, then every colour drawn.
function flat(p) {
    const out = {skyTop: p.tone.top, skyMid: p.tone.next};
    p.colours.forEach((c, i) => out["c" + i] = c);
    return out;
}

// A small seeded generator (mulberry32): the same blades for the same seed.
function random(seed) {
    let a = seed >>> 0;
    return () => {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

// Meadow's blades, in fractions of the picture: [[{x, h, w, lean}] per layer, far to near] (26 + 10 per layer, as the mockup).
function meadowBlades(seed) {
    const rnd = random(seed);
    const layers = [];
    for (let layer = 0; layer < 4; layer++) {
        const n = 26 + layer * 10;
        const blades = [];
        for (let i = 0; i < n; i++) {
            const x = rnd();
            const h = 0.14 + 0.10 * layer + rnd() * 0.18;
            const w = 0.006 + 0.003 * layer + rnd() * 0.004;
            const lean = (rnd() - 0.45) * h * 0.55;
            blades.push({x: x, h: h, w: w, lean: lean});
        }
        layers.push(blades);
    }
    return layers;
}

function num(v) {
    return (Math.round(v * 10) / 10).toString();
}

// One layer of blades as an SVG path for a picture of width w and height h (each blade a closed two-curve leaf).
function meadowPath(blades, w, h) {
    // A binding may ask while the blades are being replaced: nothing to draw yet.
    if (!Array.isArray(blades) || !(w > 0) || !(h > 0))
        return "";
    const parts = [];
    for (const b of blades) {
        const bx = b.x * w, bh = b.h * h, bw = b.w * w, lean = b.lean * h, by = h + 2;
        parts.push("M" + num(bx - bw) + " " + num(by) + "Q" + num(bx - bw * 0.4 + lean * 0.35) + " " + num(by - bh * 0.6) + " " + num(bx + lean) + " " + num(by - bh)
            + "Q" + num(bx + bw * 0.4 + lean * 0.3) + " " + num(by - bh * 0.55) + " " + num(bx + bw) + " " + num(by) + "Z");
    }
    return parts.join("");
}

// Field Rows: the band boundaries are 15 curves down the picture; band i lies between curve i and curve i + 1 (the last one
// reaches the bottom). [svg path per colour index]: each colour's bands in one path, so the order of drawing never matters.
function rowsPaths(colourCount, w, h) {
    if (!(colourCount > 0) || !(w > 0) || !(h > 0))
        return [];
    const n = 14;
    const curve = i => {
        const y0 = -h * 0.2 + i * h * 1.4 / n;
        const a = h * 0.10;
        return {y0: y0, a: a};
    };
    const top = c => "M" + num(-5) + " " + num(c.y0) + "C" + num(w * 0.3) + " " + num(c.y0 - c.a) + " " + num(w * 0.6) + " " + num(c.y0 + c.a * 1.4) + " " + num(w + 5) + " " + num(c.y0 - c.a * 0.4);
    // The same curve drawn back from right to left.
    const back = c => "L" + num(w + 5) + " " + num(c.y0 - c.a * 0.4) + "C" + num(w * 0.6) + " " + num(c.y0 + c.a * 1.4) + " " + num(w * 0.3) + " " + num(c.y0 - c.a) + " " + num(-5) + " " + num(c.y0);
    const paths = [];
    for (let k = 0; k < colourCount; k++)
        paths.push("");
    // Band "-1": above the first curve, the base colour.
    paths[0] += "M-5 -5L" + num(w + 5) + " -5" + back(curve(0)) + "Z";
    for (let i = 0; i <= n; i++) {
        const c = curve(i);
        const lower = i < n ? curve(i + 1) : null;
        let d = top(c);
        if (lower)
            d += back(lower);
        else
            d += "L" + num(w + 5) + " " + num(h + 5) + "L-5 " + num(h + 5);
        paths[i % colourCount] += d + "Z";
    }
    return paths;
}

// The stars of the night sky, in fractions of the picture (the upper half): [{x, y, r (px), alpha}].
function stars(seed, count) {
    const rnd = random(seed);
    const out = [];
    for (let i = 0; i < count; i++)
        out.push({x: rnd(), y: rnd() * 0.5, r: 0.5 + rnd() * 0.8, alpha: 0.25 + rnd() * 0.5});
    return out;
}

// Ridgeline's two hill lines for a picture of width w and height h: [far, near] SVG paths.
function ridgelinePaths(w, h) {
    return ["M0 " + num(h * 0.80) + "C" + num(w * 0.3) + " " + num(h * 0.72) + " " + num(w * 0.65) + " " + num(h * 0.86) + " " + num(w) + " " + num(h * 0.76) + "V" + num(h) + "H0Z",
        "M0 " + num(h * 0.90) + "C" + num(w * 0.35) + " " + num(h * 0.84) + " " + num(w * 0.7) + " " + num(h * 0.95) + " " + num(w) + " " + num(h * 0.88) + "V" + num(h) + "H0Z"];
}

// How many stars a night sky of w x h has (one per 9000 square pixels, as the mockup, at most 400).
function starCount(w, h) {
    return Math.max(0, Math.min(400, Math.round(w * h / 9000)));
}
