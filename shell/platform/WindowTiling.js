.pragma library

// The tiling popover's link to the compositor (docs/specs/tiling.md TL22-TL26; pure, unit-tested in tst_windowtiling): the
// plugin's `tile-hover` event (gfc/1, ADR-0007) is read here, in the platform layer (ADR-0021), and so are the outputs a
// window can move to.

var hoverStates = ["enter", "leave", "open"];

function finite(v) {
    return typeof v === "number" && isFinite(v);
}

// {address, state, light: {x, y, w, h} | null, tileable} for a `tile-hover` event, null for anything else (other types,
// foreign protocol versions, malformed text, an enter or open without a usable light). `address` is lower-case hex without
// 0x; `light` is the zoom light's rectangle in global layout coordinates (null for leave); `tileable` whether the window can
// be tiled now (the popover greys its tiles otherwise).
function parseHover(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tile-hover" || typeof msg.address !== "string" || hoverStates.indexOf(msg.state) < 0)
        return null;
    const hex = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(msg.address);
    if (!hex)
        return null;
    const address = hex[1].toLowerCase();
    if (msg.state === "leave")
        return {address: address, state: "leave", light: null, tileable: false};
    if (!finite(msg.x) || !finite(msg.y) || !finite(msg.w) || !finite(msg.h) || msg.w <= 0 || msg.h <= 0)
        return null;
    return {address: address, state: msg.state, light: {x: msg.x, y: msg.y, w: msg.w, h: msg.h}, tileable: msg.tileable === true};
}

// Where the popover opens for a light (global layout coordinates) among `screens` ([{name, x, y, width, height}], logical):
// {screen, x, y, flipY, light} in that screen's coordinates: under the light (x its middle, y its bottom), or above it (flipY,
// its top) when the screen has no room below (the overlay decides, TL22); `light` the light itself there. null when the light's
// middle is on no screen.
function popoverAnchor(light, screens) {
    if (!light || !Array.isArray(screens))
        return null;
    const cx = light.x + light.w / 2;
    const cy = light.y + light.h / 2;
    const s = screens.find(o => o && cx >= o.x && cx < o.x + o.width && cy >= o.y && cy < o.y + o.height);
    if (!s)
        return null;
    return {
        screen: s.name,
        x: cx - s.x,
        y: light.y + light.h - s.y,
        flipY: light.y - s.y,
        light: {x: light.x - s.x, y: light.y - s.y, w: light.w, h: light.h}
    };
}

// What the tiling popover never opens over (TL22, TL34; integrator review of 4ead6fb), first match: the lock ("lock"), the
// polkit sheet ("authorization"), a full-attention surface holding the keyboard (FocusReturn's holder names: Search, Apps, the
// Overview, the switcher, the Notification Center, a widget menu; "popup", the popups themselves, is left to the caller), the
// Dock's keyboard mode ("dock"). state: {locked, authorizing, holders: [name], dockKeyboard}. "" when nothing refuses it.
function hoverRefusedBy(state) {
    if (!state || state.locked !== false)
        return "lock";
    if (state.authorizing)
        return "authorization";
    const holders = Array.isArray(state.holders) ? state.holders.filter(n => n !== "popup") : [];
    if (holders.length > 0)
        return String(holders[0]);
    if (state.dockKeyboard)
        return "dock";
    return "";
}

// The outputs other than `current` ([{name, model, builtIn}], in the order of `screens`: [{name, model}]): the Move to <display>
// rows (TL23, M23). A built-in panel is the one an eDP, LVDS or DSI connector drives, as Settings > Displays decides.
function otherOutputs(screens, current) {
    if (!Array.isArray(screens))
        return [];
    return screens.filter(s => s && typeof s.name === "string" && s.name !== "" && s.name !== current).map(s => ({
        name: s.name,
        model: typeof s.model === "string" ? s.model.trim() : "",
        builtIn: /^(eDP|LVDS|DSI)-/.test(s.name)
    }));
}

// The output after `current` in `direction` ("left" or "right": by position, left to right, then top to bottom; it wraps), ""
// when there is no other output or `current` is not among `screens` ([{name, x, y}]): Super+Ctrl+Alt+Left/Right (TL26).
function nextOutput(screens, current, direction) {
    if (!Array.isArray(screens) || (direction !== "left" && direction !== "right"))
        return "";
    const all = screens.filter(s => s && typeof s.name === "string" && s.name !== "").slice().sort((a, b) => a.x !== b.x ? a.x - b.x : a.y - b.y);
    const i = all.findIndex(s => s.name === current);
    if (i < 0 || all.length < 2)
        return "";
    const n = all.length;
    return all[(i + (direction === "right" ? 1 : n - 1)) % n].name;
}

// ---- the Layouts section and the suggestions (TL27, TL28; step 4a) ----

// The class of an output for its Layouts section (owner decision T1f), from its logical size: "portrait" (taller than wide),
// "ultrawide" (aspect 21:9 or wider), "large" (1920 logical px wide or more), else "small". The same rule as the plugin's
// (compositor core classify, kLargeWidth and kUltraWideAspect), which names the class of each output in its state reply.
var largeWidth = 1920;
var ultraWideAspect = 21 / 9;

function outputClass(width, height) {
    if (!(width > 0) || !(height > 0))
        return "small";
    if (height > width)
        return "portrait";
    if (width / height >= ultraWideAspect - 1e-3)
        return "ultrawide";
    return width >= largeWidth ? "large" : "small";
}

// {gen, reason} for the plugin's `tiling` change notice (gfc/1; reason "" when it names none), null for anything else.
function parseNotice(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling" || !finite(msg.gen) || msg.gen < 0 || Math.floor(msg.gen) !== msg.gen)
        return null;
    return {gen: msg.gen, reason: typeof msg.reason === "string" ? msg.reason : ""};
}

// How long after asking an arrangement the shell still takes its suggestion (ms): the plugin answers in the same event loop
// pass, the notice and the fetch of its reply take a few frames; a suggestion later than this was not asked.
var suggestionWaitMs = 3000;

function hexAddress(text) {
    const hex = typeof text === "string" ? /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(text) : null;
    return hex ? hex[1].toLowerCase() : "";
}

// gfc1-reply: grassfield-tiling
// The pending suggestion of the reply of `hyprctl grassfield-tiling` (TL28): {gen, address, layout, output, zones: [{zone, x,
// y, w, h}], windows: [address]}: the window whose layout it fills, its empty zones in zone order with their frames (global
// layout coordinates), the windows that can fill them (addresses lower-case hex without 0x, at most 12). null when the
// reply has none, or anything in it is malformed.
function parseSuggestion(text) {
    let msg = null;
    try {
        msg = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling" || !msg.suggestion || typeof msg.suggestion !== "object")
        return null;
    const sg = msg.suggestion;
    const address = hexAddress(sg.address);
    if (!finite(sg.gen) || address === "" || typeof sg.layout !== "string" || sg.layout === "" || typeof sg.output !== "string" || sg.output === "")
        return null;
    if (!Array.isArray(sg.zones) || sg.zones.length === 0 || !Array.isArray(sg.windows) || sg.windows.length === 0 || sg.windows.length > 12)
        return null;
    const zones = [];
    for (const z of sg.zones) {
        if (!z || !finite(z.zone) || z.zone < 0 || Math.floor(z.zone) !== z.zone || !finite(z.x) || !finite(z.y) || !finite(z.w) || !finite(z.h) || z.w <= 0 || z.h <= 0)
            return null;
        zones.push({zone: z.zone, x: z.x, y: z.y, w: z.w, h: z.h});
    }
    const windows = sg.windows.map(hexAddress);
    if (windows.indexOf("") >= 0)
        return null;
    return {gen: sg.gen, address: address, layout: sg.layout, output: sg.output, zones: zones, windows: windows};
}

// How `count` suggestion tiles fit in a panel `width` x `height` (TL28): the column count that gives the largest tiles, each a
// thumbnail of aspect `aspect` (width / height) above a label `labelHeight` tall, `gap` between the tiles and around them,
// at most `maxWidth` wide. {columns, rows, tileWidth, thumbHeight, tileHeight} in whole pixels; all 0 when nothing fits.
function suggestionGrid(count, width, height, aspect, labelHeight, gap, maxWidth) {
    let best = {columns: 0, rows: 0, tileWidth: 0, thumbHeight: 0, tileHeight: 0};
    if (!(count > 0) || !(width > 0) || !(height > 0) || !(aspect > 0))
        return best;
    for (let columns = 1; columns <= count; columns++) {
        const rows = Math.ceil(count / columns);
        const byWidth = (width - gap * (columns + 1)) / columns;
        const byHeight = ((height - gap * (rows + 1)) / rows - labelHeight) * aspect;
        const tileWidth = Math.floor(Math.min(byWidth, byHeight, maxWidth));
        if (tileWidth > best.tileWidth) {
            const thumbHeight = Math.floor(tileWidth / aspect);
            best = {columns: columns, rows: rows, tileWidth: tileWidth, thumbHeight: thumbHeight, tileHeight: thumbHeight + labelHeight};
        }
    }
    return best;
}

// The tile `key` moves to from `index` among `count` tiles in rows of `columns` (TL28: the suggestions are navigable with the
// arrows): "left"/"right" the previous or next tile (wrapping over the rows), "up"/"down" the tile above or below (staying
// put at the first or last row), "home"/"end" the first or last; from -1 (none yet) any key chooses the first. -1 when there
// is no tile.
function gridStep(index, count, columns, key) {
    if (!(count > 0) || !(columns > 0))
        return -1;
    if (index < 0 || index >= count || key === "home")
        return 0;
    switch (key) {
    case "left":
        return (index + count - 1) % count;
    case "right":
        return (index + 1) % count;
    case "up":
        return index - columns >= 0 ? index - columns : index;
    case "down":
        return index + columns < count ? index + columns : index;
    case "end":
        return count - 1;
    }
    return index;
}
