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
    if (typeof o.glyph === "string" && o.glyph.trim() !== "" && o.glyph.trim().length <= 16)
        out.glyph = o.glyph.trim();
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
