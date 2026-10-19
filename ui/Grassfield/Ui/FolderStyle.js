.pragma library

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
// Unicode property escapes: clusters are cut by code point ranges (emoji sequences, combining marks, variation
// selectors, keycaps, flags). Scripts that need shaping rules (Indic conjuncts, Hangul jamo) may be cut differently
// from Qt's segmenter; both sides then still keep a single capped cluster.

const GLYPH_MAX_UNITS = 16;
const SPACE = /^[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+|[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+$/g;

function cpAt(s, i) {
    const c = s.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        const d = s.charCodeAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF)
            return ((c - 0xD800) << 10) + (d - 0xDC00) + 0x10000;
    }
    return c;
}

function inRanges(c, ranges) {
    for (let i = 0; i < ranges.length; i += 2) {
        if (c >= ranges[i] && c <= ranges[i + 1])
            return true;
    }
    return false;
}

const EXTENDERS = [0x300, 0x36F, 0x483, 0x489, 0x591, 0x5BD, 0x5BF, 0x5BF, 0x5C1, 0x5C2, 0x5C4, 0x5C5, 0x5C7, 0x5C7, 0x610, 0x61A, 0x64B, 0x65F,
                   0x670, 0x670, 0x6D6, 0x6DC, 0x6DF, 0x6E4, 0x6E7, 0x6E8, 0x6EA, 0x6ED, 0x900, 0x903, 0x93A, 0x93C, 0x93E, 0x94F, 0x951, 0x957,
                   0x962, 0x963, 0xE31, 0xE31, 0xE34, 0xE3A, 0xE47, 0xE4E, 0x1AB0, 0x1AFF, 0x1DC0, 0x1DFF, 0x200C, 0x200C, 0x20D0, 0x20FF,
                   0x302A, 0x302F, 0x3099, 0x309A, 0xFE00, 0xFE0F, 0xFE20, 0xFE2F, 0x1F3FB, 0x1F3FF, 0xE0020, 0xE007F, 0xE0100, 0xE01EF];
// What a joiner (U+200D) can join to: pictographs.
const PICTOGRAPHS = [0xA9, 0xA9, 0xAE, 0xAE, 0x203C, 0x203C, 0x2049, 0x2049, 0x2122, 0x2122, 0x2139, 0x2139, 0x2190, 0x21FF, 0x2300, 0x23FF,
                     0x24C2, 0x24C2, 0x25A0, 0x25FF, 0x2600, 0x27BF, 0x2934, 0x2935, 0x2B00, 0x2BFF, 0x3030, 0x3030, 0x303D, 0x303D,
                     0x3297, 0x3297, 0x3299, 0x3299, 0x1F000, 0x1FAFF];
// Format characters other than the joiner and the tag characters.
const FORMATS = [0xAD, 0xAD, 0x600, 0x605, 0x61C, 0x61C, 0x6DD, 0x6DD, 0x70F, 0x70F, 0x890, 0x891, 0x8E2, 0x8E2, 0x180E, 0x180E, 0x200B, 0x200C,
                 0x200E, 0x200F, 0x202A, 0x202E, 0x2060, 0x2064, 0x2066, 0x206F, 0xFEFF, 0xFEFF, 0xFFF9, 0xFFFB, 0x110BD, 0x110BD, 0x110CD, 0x110CD,
                 0x13430, 0x1343F, 0x1BCA0, 0x1BCA3, 0x1D173, 0x1D17A, 0xE0001, 0xE0001];

function rejectedCodePoint(c) {
    return c < 0x20 || (c >= 0x7F && c <= 0x9F) || (c >= 0xD800 && c <= 0xDFFF) || c === 0x2028 || c === 0x2029 || c === 0xFFFD || inRanges(c, FORMATS);
}

function unitsOf(c) {
    return c > 0xFFFF ? 2 : 1;
}

function normalizeGlyph(text) {
    const t = String(text).replace(SPACE, "");
    if (t === "")
        return "";
    const c = cpAt(t, 0);
    let i = unitsOf(c);
    if (c >= 0x1F1E6 && c <= 0x1F1FF && i < t.length) {
        const n = cpAt(t, i);
        if (n >= 0x1F1E6 && n <= 0x1F1FF)
            i += unitsOf(n);
    }
    while (i < t.length) {
        const n = cpAt(t, i);
        if (inRanges(n, EXTENDERS)) {
            i += unitsOf(n);
        } else if (n === 0x200D) {
            i += 1;
            if (i < t.length && inRanges(cpAt(t, i), PICTOGRAPHS))
                i += unitsOf(cpAt(t, i));
        } else {
            break;
        }
    }
    const cluster = t.slice(0, i);
    if (cluster.length > GLYPH_MAX_UNITS)
        return "";
    for (let k = 0; k < cluster.length; k += unitsOf(cpAt(cluster, k))) {
        if (rejectedCodePoint(cpAt(cluster, k)))
            return "";
    }
    return cluster;
}

// Code points drawn as colour emoji by default (no variation selector needed) among the BMP symbols.
const EMOJI_BMP = [0x231A, 0x231B, 0x23E9, 0x23EC, 0x23F0, 0x23F0, 0x23F3, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615, 0x2648, 0x2653, 0x267F, 0x267F,
                   0x2693, 0x2693, 0x26A1, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26CE, 0x26D4, 0x26D4, 0x26EA, 0x26EA,
                   0x26F2, 0x26F3, 0x26F5, 0x26F5, 0x26FA, 0x26FA, 0x26FD, 0x26FD, 0x2705, 0x2705, 0x270A, 0x270B, 0x2728, 0x2728, 0x274C, 0x274C,
                   0x274E, 0x274E, 0x2753, 0x2755, 0x2757, 0x2757, 0x2795, 0x2797, 0x27B0, 0x27B0, 0x27BF, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B50,
                   0x2B55, 0x2B55];

// Whether a symbol is an emoji (drawn in its own colours, opaque) rather than a plain symbol (drawn as an engraved shade).
function isEmoji(glyph) {
    const t = String(glyph);
    for (let i = 0; i < t.length; i += unitsOf(cpAt(t, i))) {
        const c = cpAt(t, i);
        if (c >= 0x1F000 || c === 0xFE0F || c === 0x20E3 || inRanges(c, EMOJI_BMP))
            return true;
    }
    return false;
}

// ---- Colour of a plain symbol (A2: icons >= 3:1) ----
// The recoloured folder plate under the symbol is close to the folder colour (measured, tokens folderIconPlate*); the
// symbol is that colour darkened in its hue until it reaches the minimum contrast against the plate, and lightened only
// when even black cannot (a black or very dark folder).

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

// The colour (#rrggbb) of a plain symbol on a folder of colour `tint` (or the theme's own colour when !recolored) in
// icon mode `mode` with icon tint `modeTint`.
function glyphShade(recolored, tint, mode, modeTint, tokens) {
    const plate = plateOf(recolored, tint, mode, modeTint, tokens);
    const lightest = lightestPlateOf(plate, mode, tokens);
    const target = tokens.folderIconGlyphMinContrast + tokens.folderIconGlyphContrastMargin;
    const hueRgb = rgbOf(mode === "tinted" && !recolored ? modeTint : (recolored ? tint : tokens.folderIconThemePlate));
    const hsl = toHsl(hueRgb);
    const at = l => fromHsl([hsl[0], hsl[1], l]);
    // Darker: the lightest shade (largest l) in the hue that reaches the target against the darkest plate.
    if (contrastRatio(at(0), plate) >= target) {
        let lo = 0, hi = hsl[2];
        for (let i = 0; i < 24; i++) {
            const mid = (lo + hi) / 2;
            if (contrastRatio(at(mid), plate) >= target)
                lo = mid;
            else
                hi = mid;
        }
        return hexOf(at(lo));
    }
    // A plate too dark for a darker symbol: lighten (the smallest l that reaches the target, else white).
    if (contrastRatio(at(1), lightest) < target)
        return "#ffffff";
    let lo = hsl[2], hi = 1;
    for (let i = 0; i < 24; i++) {
        const mid = (lo + hi) / 2;
        if (contrastRatio(at(mid), lightest) >= target)
            hi = mid;
        else
            lo = mid;
    }
    return hexOf(at(hi));
}
