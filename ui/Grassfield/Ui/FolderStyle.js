.pragma library
.import "GraphemeData.js" as Data
.import "IconModes.js" as Modes

// Folder colours and a folder's own look (docs/specs/ui.md "Folder colours"). Pure functions, no I/O, nothing shared
// with the icon appearance modes (IconModes.js): the colour step is separate from the mode step.
//
// A colour setting is "theme" (the icon theme's own folder colour), "accent" (follow the accent colour) or "#rrggbb".
// The global one is `icons.folderColor`; a folder's own one is stored on the folder (apps/files/src/folderstylelogic.h,
// the same format): {"v":1,"color":"#ff9500","glyph":"🎵"}.

const HEX = /^#[0-9a-fA-F]{6}$/;

function validColor(setting) {
    return setting === "theme" || setting === "accent" || (typeof setting === "string" && HEX.test(setting));
}

// A valid setting as is, else "theme".
function normalizeColor(setting) {
    return validColor(setting) ? setting : "theme";
}

// Whether a setting recolours the icon: only "theme" (and anything invalid) keeps the theme's own colour; then no
// effect item exists at all.
function recolors(setting) {
    return validColor(setting) && setting !== "theme";
}

// The colour of a folder: its own setting ("" = none), else the global one.
function effectiveColor(own, global) {
    return validColor(own) ? own : normalizeColor(global);
}

// The colour a setting stands for: the hex colour, else (for "accent") `accent`.
function colorOf(setting, accent) {
    return typeof setting === "string" && HEX.test(setting) ? setting : accent;
}

// Icon names of folders: a theme's folder, its special folders (folder-documents, ...), KDE's inode-directory.
function isFolderIconName(name) {
    return typeof name === "string" && (name === "inode-directory" || name === "folder" || name.indexOf("folder-") === 0);
}

// MultiEffect parameters recolouring a folder icon with `tint`: the luminance of the theme's folder (shape, flap and
// shading) mapped onto the colour, alpha kept. `tokens`: the Tokens singleton (folderIcon group).
function effect(tint, tokens) {
    return {saturation: tokens.folderIconSaturation, brightness: tokens.folderIconBrightness, contrast: tokens.folderIconContrast,
            colorization: tokens.folderIconColorization, colorizationColor: tint};
}

// A stored value (a folder's attribute or the per-user store entry) as {color, glyph}; invalid fields are dropped.
function parse(text) {
    const out = {color: "", glyph: ""};
    let o = null;
    try {
        o = JSON.parse(String(text));
    } catch (e) {
        return out;
    }
    if (o === null || typeof o !== "object" || Array.isArray(o))
        return out;
    if (typeof o.color === "string" && validColor(o.color))
        out.color = o.color.toLowerCase();
    if (typeof o.glyph === "string")
        out.glyph = normalizeGlyph(o.glyph);
    return out;
}

// ---- Shell side (the desktop reads folders it did not create) ----

// UTF-8 text of a hex string ("7b22..."), "" when malformed.
function hexToText(hex) {
    if (typeof hex !== "string" || hex.length === 0 || hex.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(hex))
        return "";
    let escaped = "";
    for (let i = 0; i < hex.length; i += 2)
        escaped += "%" + hex.substr(i, 2);
    try {
        return decodeURIComponent(escaped);
    } catch (e) {
        return "";
    }
}

// Output of `getfattr -h -d -e hex -m ^user\.grassfield\.folder$ --absolute-names -- <paths>`: blocks of
//   # file: /abs/path
//   user.grassfield.folder=0x7b...
// -> {path: {color, glyph}} for the folders that hold a valid look. Paths getfattr prints with C escapes (unusual
// characters) are skipped: those folders show the global colour.
function parseGetfattr(text) {
    const out = {};
    let path = "";
    for (const line of String(text).split("\n")) {
        if (line.indexOf("# file: ") === 0) {
            path = line.slice(8);
            if (path.indexOf("\\") >= 0 || path.indexOf('"') >= 0 || path.charAt(0) !== "/")
                path = "";
            continue;
        }
        const m = /^user\.grassfield\.folder=0x([0-9a-fA-F]+)$/.exec(line);
        if (m && path !== "") {
            const style = parse(hexToText(m[1]));
            if (style.color !== "" || style.glyph !== "")
                out[path] = style;
        }
    }
    return out;
}

// The per-user fallback store (folder-styles.json, apps/files/src/folderstylestore.h): {serial, folders: {path: style}};
// a file that is not a version 1 store reads as empty.
function parseStore(text) {
    const empty = {serial: 0, folders: {}};
    let o = null;
    try {
        o = JSON.parse(String(text));
    } catch (e) {
        return empty;
    }
    if (o === null || typeof o !== "object" || o.version !== 1 || o.folders === null || typeof o.folders !== "object")
        return empty;
    const folders = {};
    for (const key of Object.keys(o.folders)) {
        if (key.charAt(0) !== "/")
            continue;
        const style = parse(JSON.stringify(o.folders[key]));
        if (style.color !== "" || style.glyph !== "")
            folders[key] = style;
    }
    return {serial: typeof o.serial === "number" ? o.serial : 0, folders: folders};
}

// The look of `path`: the store's entry wins over the attribute (same precedence as Files), else none.
function lookup(path, store, attributes) {
    if (store && store[path])
        return store[path];
    if (attributes && attributes[path])
        return attributes[path];
    return {color: "", glyph: ""};
}


// ---- The symbol rule (the same as FolderStyleLogic::normalizeGlyph, apps/files/src/folderstylelogic.cpp) ----
// The first grapheme cluster of the text (white space around it trimmed); "" when empty, longer than 16 UTF-16 units, or
// when it holds a control, format (bidi marks, zero width space; the emoji joiner and tag characters are allowed),
// line/paragraph separator, lone surrogate or replacement character. QML's JavaScript has neither Intl.Segmenter nor
// Unicode property escapes: the clusters are cut by the whole of UAX #29 (extended grapheme clusters: GB3 to GB13, with
// GB9b prepended characters and GB9c Indic conjuncts) over GraphemeData.js, which is generated from the Unicode
// properties (scripts/dev/gen-glyph-tables.sh, the same data as Files' apps/files/src/graphemedata.inc): both sides run
// one algorithm over one set of data, tests/fixtures/glyph-vectors.json holds both to the same answers, and
// scripts/dev/glyph-icu-compare.sh checks them against ICU's own segmenter.


const GLYPH_MAX_UNITS = 16;
const SPACE = /^[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/g;

// Class bits (GlyphClass, apps/files/src/folderstylelogic.h).
const EXTEND = 1, SPACING = 2, JOINER = 4, REGIONAL = 8, PICTOGRAPH = 16, HANGUL_L = 32, HANGUL_V = 64, HANGUL_T = 128,
    CONSONANT = 256, LINKER = 512, CONTROL = 1024, REJECTED = 2048, EMOJI = 4096, PREPEND = 8192, INCB_EXTEND = 16384;
const HANGUL_FIRST = 0xAC00, HANGUL_LAST = 0xD7A3;
// Hangul kinds: 0 none, 1 L, 2 V, 3 T, 4 LV, 5 LVT.

function cpAt(s, i) {
    const c = s.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        const d = s.charCodeAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF)
            return ((c - 0xD800) << 10) + (d - 0xDC00) + 0x10000;
    }
    return c;
}

function unitsOf(c) {
    return c > 0xFFFF ? 2 : 1;
}

// The class mask of a code point: binary search in the generated runs [first, last, mask, ...].
function classesOf(cp) {
    const runs = Data.CLASSES;
    let lo = 0, hi = runs.length / 3 - 1;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (cp < runs[3 * mid])
            hi = mid - 1;
        else if (cp > runs[3 * mid + 1])
            lo = mid + 1;
        else
            return runs[3 * mid + 2];
    }
    return 0;
}

function hangulOf(cp, classes) {
    if (cp >= HANGUL_FIRST && cp <= HANGUL_LAST)
        return (cp - HANGUL_FIRST) % 28 === 0 ? 4 : 5;
    if (classes & HANGUL_L)
        return 1;
    if (classes & HANGUL_V)
        return 2;
    if (classes & HANGUL_T)
        return 3;
    return 0;
}

// The end (UTF-16 units) of the first cluster of a non-empty text (the same algorithm as firstClusterEnd in
// apps/files/src/folderstylelogic.cpp).
function firstClusterEnd(t) {
    const first = cpAt(t, 0);
    const firstClasses = classesOf(first);
    let end = unitsOf(first);
    if (firstClasses & CONTROL) {
        if (first === 0x0D && end < t.length && t.charCodeAt(end) === 0x0A)
            end++;                                        // GB3: CR x LF; GB4/GB5: any other control stands alone
        return end;
    }
    let hangul = hangulOf(first, firstClasses);
    let prepended = (firstClasses & PREPEND) !== 0;
    let regionals = (firstClasses & REGIONAL) ? 1 : 0;
    let pict = (firstClasses & PICTOGRAPH) ? 1 : 0;      // 0 none, 1 an ExtPict (Extend*) seen, 2 ... then the joiner
    let conjunct = (firstClasses & CONSONANT) ? 1 : 0;   // 1 a consonant seen, 2 ... then a linker
    while (end < t.length) {
        const cp = cpAt(t, end);
        const classes = classesOf(cp);
        if (classes & CONTROL)
            break;
        const h = hangulOf(cp, classes);
        let join = false;
        if (hangul === 1 && h !== 0 && h !== 3)
            join = true;
        else if ((hangul === 4 || hangul === 2) && (h === 2 || h === 3))
            join = true;
        else if ((hangul === 5 || hangul === 3) && h === 3)
            join = true;
        if (!join && (classes & (EXTEND | JOINER | SPACING)))
            join = true;                                  // GB9, GB9a
        if (!join && prepended)
            join = true;                                  // GB9b
        if (!join && (classes & CONSONANT) && conjunct === 2)
            join = true;                                  // GB9c
        if (!join && (classes & PICTOGRAPH) && pict === 2)
            join = true;                                  // GB11
        if (!join && (classes & REGIONAL) && regionals % 2 === 1)
            join = true;                                  // GB12, GB13
        if (!join)
            break;
        hangul = h;
        prepended = (classes & PREPEND) !== 0;
        regionals = (classes & REGIONAL) ? regionals + 1 : 0;
        if (classes & PICTOGRAPH)
            pict = 1;
        else if (pict === 1 && (classes & EXTEND))
            pict = 1;
        else if (pict === 1 && (classes & JOINER))
            pict = 2;
        else
            pict = 0;
        if (classes & CONSONANT)
            conjunct = 1;
        else if (classes & LINKER)
            conjunct = conjunct >= 1 ? 2 : 0;
        else if (!(classes & INCB_EXTEND))
            conjunct = 0;
        end += unitsOf(cp);
    }
    return end;
}

function normalizeGlyph(text) {
    const t = String(text).replace(SPACE, "");
    if (t === "")
        return "";
    let cluster = t.slice(0, firstClusterEnd(t));
    // A joiner with nothing to join is invisible baggage: it is dropped ("a" + joiner + star keeps the "a").
    while (cluster.length > 0 && cluster.charCodeAt(cluster.length - 1) === 0x200D)
        cluster = cluster.slice(0, -1);
    if (cluster === "" || cluster.length > GLYPH_MAX_UNITS)
        return "";
    for (let k = 0; k < cluster.length; k += unitsOf(cpAt(cluster, k))) {
        if (classesOf(cpAt(cluster, k)) & REJECTED)
            return "";
    }
    return cluster;
}

// Whether a symbol is drawn as a colour emoji (opaque, its own colours) rather than as an engraved shade: the emoji
// selector (U+FE0F), a keycap, or a character with the Emoji property (not the ASCII digits, # and *), unless the text
// selector (U+FE0E) is in it.
// (Text-by-default emoji characters such as an umbrella count as emoji without it: this system's fonts draw them in
// colour.) The same as FolderStyleLogic::isEmoji.
function isEmoji(glyph) {
    const t = String(glyph);
    let emoji = false;
    for (let i = 0; i < t.length; i += unitsOf(cpAt(t, i))) {
        const c = cpAt(t, i);
        if (c === 0xFE0E)
            return false;
        if (c === 0xFE0F || c === 0x20E3 || (classesOf(c) & EMOJI))
            emoji = true;
    }
    return emoji;
}

// ---- Colour of a plain symbol (A2: icons >= 3:1) ----
// The symbol is an engraved shade of the plate's hue: darker or lighter than the plate, whichever the icon mode asks for
// (`prefersLighter`) and the plate allows, until it reaches the minimum contrast against the plate. The plate is MEASURED,
// once per icon file and size bucket and independent of the colour, the icon mode and the appearance: FolderPlate reads
// the RAW icon's pixels under the symbol (`sampleBox`), and the plate of any combination is then computed from those
// samples by the same shader arithmetic as Qt's MultiEffect (`effectSamples`: the icon mode, then the folder colour,
// `plateThrough`), so a new colour, mode or appearance never needs another measure. The estimate (`plateOf`) only serves
// until the samples are known, and when they cannot be read (no icon).

function rgbOf(color) {
    if (color !== null && typeof color === "object")
        return [color.r, color.g, color.b];
    const m = /^#(?:[0-9a-fA-F]{2})?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/.exec(String(color));
    if (!m)
        return [0, 0, 0];
    return [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255];
}

function hexOf(rgb) {
    let out = "#";
    for (const v of rgb)
        out += ("0" + Math.max(0, Math.min(255, Math.round(v * 255))).toString(16)).slice(-2);
    return out;
}

function relativeLuminance(rgb) {
    const f = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    return 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2]);
}

function contrastRatio(a, b) {
    const la = relativeLuminance(a), lb = relativeLuminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function toHsl(rgb) {
    const r = rgb[0], g = rgb[1], b = rgb[2];
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const l = (max + min) / 2;
    if (max === min)
        return [0, 0, l];
    const d = max - min;
    const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    let h;
    if (max === r)
        h = (g - b) / d + (g < b ? 6 : 0);
    else if (max === g)
        h = (b - r) / d + 2;
    else
        h = (r - g) / d + 4;
    return [h / 6, s, l];
}

function fromHsl(hsl) {
    const h = hsl[0], s = hsl[1], l = hsl[2];
    if (s === 0)
        return [l, l, l];
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    const channel = t => {
        if (t < 0)
            t += 1;
        if (t > 1)
            t -= 1;
        if (t < 1 / 6)
            return p + (q - p) * 6 * t;
        if (t < 1 / 2)
            return q;
        if (t < 2 / 3)
            return p + (q - p) * (2 / 3 - t) * 6;
        return p;
    };
    return [channel(h + 1 / 3), channel(h), channel(h - 1 / 3)];
}

// The estimated plate colour (rgb 0..1) under a symbol: the folder colour when the folder is recoloured, else the icon
// theme's own folder plate; scaled by the icon mode (default: the recolour alone; Dark and Tinted lower it, Tinted by
// the luminance of the icon tint `modeTint`; in Tinted mode the theme's own folder takes the tint's hue).
function plateOf(recolored, tint, mode, modeTint, tokens) {
    const tintRgb = rgbOf(modeTint);
    if (mode === "tinted") {
        if (!recolored) {
            const g = tokens.folderIconThemeTintedGain;
            return [Math.min(1, tintRgb[0] * g), Math.min(1, tintRgb[1] * g), Math.min(1, tintRgb[2] * g)];
        }
        const f = Math.max(0.3, Math.min(1, tokens.folderIconPlateTintedBase + tokens.folderIconPlateTintedSlope * relativeLuminance(tintRgb)));
        const b = rgbOf(tint);
        return [b[0] * f, b[1] * f, b[2] * f];
    }
    const base = rgbOf(recolored ? tint : tokens.folderIconThemePlate);
    let k = recolored ? tokens.folderIconPlateDefault : 1;
    if (mode === "dark")
        k = recolored ? tokens.folderIconPlateDark : tokens.folderIconPlateDark / tokens.folderIconPlateDefault;
    return [base[0] * k, base[1] * k, base[2] * k];
}

// The lightest the plate can be: in Clear mode the plate is translucent and a dark one shows the backdrop through.
function lightestPlateOf(plate, mode, tokens) {
    if (mode !== "clear")
        return plate;
    const lift = tokens.folderIconClearLift;
    return [plate[0] + (1 - plate[0]) * lift, plate[1] + (1 - plate[1]) * lift, plate[2] + (1 - plate[2]) * lift];
}

// Which way a plain symbol is engraved in an icon mode, one rule per mode so that the folders of a view agree: Dark engraves
// the lighter shade (the mode darkens its folders); Tinted does when the mode's own folder plate (`reference`, the relative
// luminance of the theme's folder plate through the mode) is dark; Default and Clear engrave the darker shade (macOS 26). A
// plate that cannot reach the contrast that way (a black folder in Default, a pale one in Dark) takes the other shade.
function prefersLighter(mode, reference, tokens) {
    if (mode === "dark")
        return true;
    if (mode === "tinted")
        return reference < tokens.folderIconGlyphLighterBelow;
    return false;
}

// The colour (#rrggbb) of a plain symbol on a folder of colour `tint` (or the theme's own colour when !recolored) in
// icon mode `mode` with icon tint `modeTint`. `measured`: the plate computed from the icon's samples ({dark, light, hue, ref},
// see plateThrough), else the estimate.
function glyphShade(recolored, tint, mode, modeTint, tokens, measured) {
    const hasMeasure = measured !== undefined && measured !== null && measured.dark !== undefined;
    const plate = hasMeasure ? measured.dark : plateOf(recolored, tint, mode, modeTint, tokens);
    const lightest = hasMeasure ? measured.light : lightestPlateOf(plate, mode, tokens);
    const reference = hasMeasure && measured.ref !== undefined ? measured.ref : relativeLuminance(plateOf(false, "", mode, modeTint, tokens));
    const target = tokens.folderIconGlyphMinContrast + tokens.folderIconGlyphContrastMargin;
    const hueRgb = recolored ? rgbOf(tint) : (hasMeasure ? measured.hue : rgbOf(mode === "tinted" ? modeTint : tokens.folderIconThemePlate));
    const hsl = toHsl(hueRgb);
    const at = l => fromHsl([hsl[0], hsl[1], l]);
    const darkerOk = contrastRatio(at(0), plate) >= target;
    const lighterOk = contrastRatio(at(1), lightest) >= target;
    // Darker: the lightest shade (largest l) in the hue that reaches the target against the darkest plate.
    const darker = () => {
        let lo = 0, hi = hsl[2];
        for (let i = 0; i < 24; i++) {
            const mid = (lo + hi) / 2;
            if (contrastRatio(at(mid), plate) >= target)
                lo = mid;
            else
                hi = mid;
        }
        return hexOf(at(lo));
    };
    // Lighter: the smallest l that reaches the target against the lightest plate.
    const lighter = () => {
        let lo = hsl[2], hi = 1;
        for (let i = 0; i < 24; i++) {
            const mid = (lo + hi) / 2;
            if (contrastRatio(at(mid), lightest) >= target)
                hi = mid;
            else
                lo = mid;
        }
        return hexOf(at(hi));
    };
    if (prefersLighter(mode, reference, tokens) && lighterOk)
        return lighter();
    if (darkerOk)
        return darker();
    if (lighterOk)
        return lighter();
    // Neither reaches it (a mid-grey plate under a margin this large): the better of black and white.
    return contrastRatio(at(0), plate) >= contrastRatio(at(1), lightest) ? hexOf(at(0)) : hexOf(at(1));
}

// ---- The plate from samples of the raw icon ----

// Samples of the pixels of a box [x0, x1) x [y0, y1) of an image (`data` = RGBA bytes, straight alpha, row after row,
// `width` wide): a grid of at most n x n of them as one flat array [r, g, b, a, ...] (0..1), null when the box holds no
// pixel or only transparent ones. A small fixed number whatever the icon size: everything after it is cheap.
function sampleBox(data, width, height, x0, y0, x1, y1, n) {
    const xa = Math.max(0, Math.floor(x0)), xb = Math.min(width, Math.ceil(x1));
    const ya = Math.max(0, Math.floor(y0)), yb = Math.min(height, Math.ceil(y1));
    const w = xb - xa, h = yb - ya;
    if (w <= 0 || h <= 0)
        return null;
    const nx = Math.min(n, w), ny = Math.min(n, h);
    const out = [];
    let opaque = false;
    for (let j = 0; j < ny; j++) {
        const y = ya + Math.floor((j + 0.5) * h / ny);
        for (let i = 0; i < nx; i++) {
            const x = xa + Math.floor((i + 0.5) * w / nx);
            const k = 4 * (y * width + x);
            out.push(data[k] / 255, data[k + 1] / 255, data[k + 2] / 255, data[k + 3] / 255);
            if (data[k + 3] > 0)
                opaque = true;
        }
    }
    return opaque ? out : null;
}

// One MultiEffect stage over samples, the arithmetic of Qt's multieffect shader (checked against the compiled shader's
// source): on the colour c with alpha a (premultiplied), c = (c - 0.5a) (1 + contrast) + 0.5a + brightness a; gray =
// dot(c, (0.299, 0.587, 0.114)); c = tint gray w + c (1 - w) with w = colorization; c = mix(gray, c, 1 + saturation);
// alpha times opacity. Everything is homogeneous in a, so it is done on the straight colour. `p`: the parameters of
// IconModes.effect or effect(); each stage's result is clamped to 0..1 (the layer or the screen is 8 bits).
function effectSamples(samples, p) {
    const col = rgbOf(p.colorizationColor);
    const k = 1 + p.contrast, b = p.brightness, w = p.colorization, sat = 1 + p.saturation;
    const opacity = p.opacity === undefined ? 1 : p.opacity;
    const out = new Array(samples.length);
    const clamp = v => Math.max(0, Math.min(1, v));
    for (let i = 0; i < samples.length; i += 4) {
        const r = (samples[i] - 0.5) * k + 0.5 + b;
        const g = (samples[i + 1] - 0.5) * k + 0.5 + b;
        const bl = (samples[i + 2] - 0.5) * k + 0.5 + b;
        const gray = 0.299 * r + 0.587 * g + 0.114 * bl;
        out[i] = clamp(gray + (col[0] * gray * w + r * (1 - w) - gray) * sat);
        out[i + 1] = clamp(gray + (col[1] * gray * w + g * (1 - w) - gray) * sat);
        out[i + 2] = clamp(gray + (col[2] * gray * w + bl * (1 - w) - gray) * sat);
        out[i + 3] = samples[i + 3] * opacity;
    }
    return out;
}

// The plate under a symbol from samples: every sample is composited over `backdrop` (rgb 0..1; a translucent plate, Clear
// mode, shows the view behind it), `dark` = the mean of the darkest quarter, `light` = the mean of the lightest quarter, `hue`
// = the mean colour weighted by alpha, `mean` = the mean of the composites. All rgb 0..1.
function plateSummary(samples, backdrop) {
    const bd = backdrop === undefined || backdrop === null ? [0, 0, 0] : backdrop;
    const comp = [];
    const sum = [0, 0, 0], total = [0, 0, 0];
    let weight = 0;
    for (let i = 0; i < samples.length; i += 4) {
        const a = samples[i + 3];
        const c = [samples[i] * a + bd[0] * (1 - a), samples[i + 1] * a + bd[1] * (1 - a), samples[i + 2] * a + bd[2] * (1 - a)];
        comp.push({c: c, l: relativeLuminance(c)});
        for (let q = 0; q < 3; q++) {
            sum[q] += samples[i + q] * a;
            total[q] += c[q];
        }
        weight += a;
    }
    if (comp.length === 0 || weight <= 0)
        return null;
    comp.sort((p, q) => p.l - q.l);
    const n = Math.max(1, Math.ceil(comp.length / 4));
    const dark = [0, 0, 0], light = [0, 0, 0];
    for (let i = 0; i < n; i++) {
        for (let q = 0; q < 3; q++) {
            dark[q] += comp[i].c[q] / n;
            light[q] += comp[comp.length - 1 - i].c[q] / n;
        }
    }
    return {dark: dark, light: light, hue: [sum[0] / weight, sum[1] / weight, sum[2] / weight], mean: [total[0] / comp.length, total[1] / comp.length, total[2] / comp.length]};
}

// The plate of a combination from the raw icon's samples: through the icon mode (IconModes.effect) and then, when the folder
// is recoloured, through the folder colour (effect). `modeTint`: the icon tint (only Tinted uses it); `tint`: the folder
// colour; `backdrop`: rgb of the view behind a translucent plate. Adds `ref`: the relative luminance of the mode's own
// folder plate (no folder colour), what `prefersLighter` reads. null when there is nothing to read.
function plateThrough(samples, mode, modeTint, recolored, tint, backdrop, tokens) {
    const m = Modes.effect(mode, modeTint, tokens);
    const modeSamples = m.enabled ? effectSamples(samples, m) : samples;
    const own = plateSummary(modeSamples, backdrop);
    if (own === null)
        return null;
    const out = recolored ? plateSummary(effectSamples(modeSamples, effect(tint, tokens)), backdrop) : own;
    if (out === null)
        return null;
    return {dark: out.dark, light: out.light, hue: out.hue, ref: relativeLuminance(own.mean)};
}

// The symbol's box in a square icon image of edge `size`: [x0, y0, x1, y1] (tokens glyphScale, glyphCenterY).
function glyphBox(size, tokens) {
    const half = size * tokens.folderIconGlyphScale / 2;
    const cy = size * tokens.folderIconGlyphCenterY;
    return [size / 2 - half, cy - half, size / 2 + half, cy + half];
}
