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
// be tiled now (the popover greys its tiles otherwise); `splittable` whether it also fits half of its output's Split View
// (TL33, TL8: the popover greys Left and Right of Screen otherwise); `fit` {zones, places} the zones and the places its minimum
// does not fit (ADR-0036 D69, fitNames: the popover greys those arrangements, Layouts zones and places; both [] for leave and
// for an older plugin, which offers everything).
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
        return {address: address, state: "leave", light: null, tileable: false, splittable: false, fit: noFit()};
    if (!finite(msg.x) || !finite(msg.y) || !finite(msg.w) || !finite(msg.h) || msg.w <= 0 || msg.h <= 0)
        return null;
    return {address: address, state: msg.state, light: {x: msg.x, y: msg.y, w: msg.w, h: msg.h}, tileable: msg.tileable === true, splittable: msg.splittable === true,
        fit: {zones: fitNames(msg.unfitZones), places: fitNames(msg.unfitPlaces)}};
}

// ---- what a window fits (ADR-0036 D69) ----

// At most this many names in a list, each at most kMaxFitName characters (the plugin lists 26 zones and 13 places at most).
var kMaxFitNames = 64;
var kMaxFitName = 24;

// The names of a list of the plugin (a zone "x,y,w,h" in twelfths, a place "top-left"): the strings of at most kMaxFitName
// characters, at most kMaxFitNames of them; [] for a missing or malformed list.
function fitNames(list) {
    return (Array.isArray(list) ? list : []).filter(n => typeof n === "string" && n.length > 0 && n.length <= kMaxFitName).slice(0, kMaxFitNames);
}

// A window that fits everything (nothing known, or an older plugin): nothing greyed, the plugin still refuses what does not fit.
function noFit() {
    return {zones: [], places: []};
}

// A zone [x, y, w, h] in twelfths (a glyph token) as the plugin names it: "x,y,w,h".
function zoneKey(zone) {
    return Array.isArray(zone) && zone.length === 4 ? zone.join(",") : "";
}

// The window fits place `place` ("left", "top-left", "left-third"…; Fill and Center always fit) with fit {zones, places}.
function placeFits(fit, place) {
    return place === "fill" || place === "center" || !fit || (fit.places || []).indexOf(place) < 0;
}

// The window fits zone `zone` ([x, y, w, h]: a Layouts zone, or an arrangement's first zone, its own) with fit {zones, places}.
function zoneFits(fit, zone) {
    const key = zoneKey(zone);
    return key === "" || !fit || (fit.zones || []).indexOf(key) < 0;
}

// gfc1-reply: grassfield-tiling
// The zones and the places each window does not fit, from the reply of `hyprctl grassfield-tiling` ("unfitZones", D69): an
// object keyed by lower-case hex address without 0x, each {zones, places} (fitNames); a malformed entry left out; null when
// the reply is malformed (an older plugin's reply, without "unfitZones", lists none).
function parseUnfitZones(text) {
    let msg = null;
    try {
        msg = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling")
        return null;
    const out = {};
    (Array.isArray(msg.unfitZones) ? msg.unfitZones : []).forEach(w => {
        const a = w && typeof w === "object" ? hexAddress(w.address) : "";
        if (a !== "")
            out[a] = {zones: fitNames(w.zones), places: fitNames(w.places)};
    });
    return out;
}

// What window `address` (any address form) does not fit, from parseUnfitZones' object (null or not listed: it fits
// everything, noFit).
function fitOf(unfitZones, address) {
    const a = hexAddress(address);
    return a !== "" && unfitZones && unfitZones[a] ? unfitZones[a] : noFit();
}

// What a click on the green light does while its tiling popover is open (ADR-0036 D64: the overlay takes that click, the
// plugin never sees it), as the plugin's own light (Titlebar.cpp zoomLight, core zoomAction): a Split View member leaves the
// Split View ("unsplit"), a full-screen window leaves full screen ("leaveFullscreen"), with Alt a window enters it
// ("enterFullscreen"), else Zoom and back ("toggleZoom").
function greenAction(fullscreen, inSplit, altHeld) {
    if (inSplit)
        return "unsplit";
    if (fullscreen)
        return "leaveFullscreen";
    return altHeld ? "enterFullscreen" : "toggleZoom";
}

// Where a press on the overlay's menu bar strip goes while a popup is open (ADR-0036 D64; integrator review of 7096305,
// MAJOR 1): to the output's bar while it is in view ("bar"); with the bar away (full screen, a Split View Desktop, where a
// member's titlebar starts at the output's top, under the strip) the strip is any click outside: the tiling popover's
// green light ("green", `onLight`: a left press on it) or a close ("close").
function stripPress(barInView, onLight) {
    if (barInView)
        return "bar";
    return onLight ? "green" : "close";
}

// Whether (x, y) is on the light `light` ({x, y, w, h}, the same coordinates; null: no light): its right and bottom edges excluded.
function inLight(light, x, y) {
    return !!light && x >= light.x && x < light.x + light.w && y >= light.y && y < light.y + light.h;
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
// pass, the notice and the fetch of its reply take a few frames; a suggestion later than this was not asked. Generous for a
// loaded machine, where starting `hyprctl` alone can take seconds (integrator, merge note of #56; ADR-0036 D68): a reply
// still on its way when it ends is dropped and fetched once more after a third of it.
var suggestionWaitMs = 6000;

// The plugin's titlebar-reveal event (ADR-0036 D65; ADR-0015 P6): {output, revealed}, the titlebar of a full-screen window
// on that output revealed at the top edge, or away; null for anything else.
function parseTitlebarReveal(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "titlebar-reveal" || typeof msg.output !== "string" || msg.output === "" || typeof msg.revealed !== "boolean")
        return null;
    return {output: msg.output, revealed: msg.revealed};
}

// The outputs whose full-screen titlebar is revealed (names) after `reveal` (parseTitlebarReveal): a new list, each name once.
function revealsAfter(reveals, reveal) {
    const out = (Array.isArray(reveals) ? reveals : []).filter(name => name !== reveal.output);
    if (reveal.revealed)
        out.push(reveal.output);
    return out;
}

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

// The keyboard's tile of the suggestions among the tiles `windows` (TL28; #48 nested pass, MINOR D: macOS selects the first
// window as the picker opens, and a first Return takes it): the first one when `reset` (a new suggestion) or when `index` is
// out of range (none yet, or the windows changed under it); else `index` stays. -1 when there is no tile, `windows` not yet
// evaluated included (undefined while the picker is created: #48's merge note, a TypeError at each open).
function keptSelection(index, windows, reset) {
    const count = Array.isArray(windows) ? windows.length : 0;
    if (count === 0)
        return -1;
    return reset || !(index >= 0 && index < count) ? 0 : index;
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

// After a pick of the suggestions (TL28) the panel takes no second pick until the plugin's next suggestion; the `tiling`
// notice of a refusal (reason "invalid": the zone was taken meanwhile; "locked") changed nothing: it takes a pick again.
function pickPending(pending, reason) {
    return pending === true && reason !== "invalid" && reason !== "locked";
}

// ---- tile groups (TL29; step 4b) ----

// gfc1-reply: grassfield-tiling
// The tile groups of the reply of `hyprctl grassfield-tiling`: {groupOf: {address: group}, members: {group: [address]}}
// (addresses lower-case hex without 0x, in the reply's order; group the plugin's number as a string). Every window with a
// group counts, a suspended one (minimized) too; a group of fewer than two windows is left out. null when the reply is
// malformed.
function parseGroups(text) {
    let msg = null;
    try {
        msg = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling" || !Array.isArray(msg.outputs))
        return null;
    const members = {};
    for (const o of msg.outputs) {
        for (const w of (o && Array.isArray(o.windows) ? o.windows : [])) {
            const address = w ? hexAddress(w.address) : "";
            if (address === "" || !finite(w.group) || w.group <= 0)
                continue;
            const key = String(w.group);
            members[key] = (members[key] || []).concat([address]);
        }
    }
    const groupOf = {};
    for (const key of Object.keys(members)) {
        if (members[key].length < 2) {
            delete members[key];
            continue;
        }
        for (const a of members[key])
            groupOf[a] = key;
    }
    return {groupOf: groupOf, members: members};
}

// gfc1-reply: grassfield-tiling
// The Split View Desktops of the reply of `hyprctl grassfield-tiling` (docs/specs/tiling.md TL33): [{workspace, output, home,
// windows, waiting}] (Hyprland's ids of the Split View Desktop and of the Desktop it came from, its output's name, its members
// lower-case hex without 0x, whether its one member still waits for its second window), in the reply's order. An entry
// without positive whole ids or an output name is left out, a malformed member too; null when the reply is malformed (an
// older plugin's reply, without "splits", lists none).
function parseSplits(text) {
    let msg = null;
    try {
        msg = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling")
        return null;
    const out = [];
    for (const d of (Array.isArray(msg.splits) ? msg.splits : [])) {
        const whole = v => finite(v) && Math.floor(v) === v && v > 0;
        if (!d || !whole(d.workspace) || !whole(d.home) || typeof d.output !== "string" || d.output === "")
            continue;
        const windows = (Array.isArray(d.windows) ? d.windows : []).map(hexAddress).filter(a => a !== "");
        out.push({workspace: d.workspace, output: d.output, home: d.home, windows: windows, waiting: d.waiting === true});
    }
    return out;
}

// gfc1-reply: grassfield-tiling
// The windows of the reply of `hyprctl grassfield-tiling` that do not fit half of their output (ADR-0036 D57: the Window
// menu greys their Full Screen Tile), lower-case hex without 0x, a malformed one left out; null when the reply is malformed
// (an older plugin's reply, without "unfit", lists none).
function parseUnfit(text) {
    let msg = null;
    try {
        msg = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling")
        return null;
    return (Array.isArray(msg.unfit) ? msg.unfit : []).map(hexAddress).filter(a => a !== "");
}

// Window `address` (any address form) fits half of its output: it is not among `unfit` (parseUnfit; null or [] when not
// known: it fits, the plugin still refuses it if not).
function fitsHalf(unfit, address) {
    const a = hexAddress(address);
    return a === "" || (unfit || []).indexOf(a) < 0;
}

// gfc1-reply: grassfield-tiling
// The windows of fixed size of the reply of `hyprctl grassfield-tiling` (minimum = maximum: their zoom light is disabled, and
// the Window menu greys their Zoom, Enter Full Screen and tiling items; ADR-0040 step 1b), lower-case hex without 0x, a
// malformed one left out; null when the reply is malformed (an older plugin's reply, without "fixed", lists none).
function parseFixed(text) {
    let msg = null;
    try {
        msg = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling")
        return null;
    return (Array.isArray(msg.fixed) ? msg.fixed : []).map(hexAddress).filter(a => a !== "");
}

// Window `address` (any address form) is of fixed size: it is among `fixed` (parseFixed; null or [] when not known: it is
// not, and the plugin still opens nothing from its zoom light).
function isFixed(fixed, address) {
    const a = hexAddress(address);
    return a !== "" && (fixed || []).indexOf(a) >= 0;
}

// gfc1-reply: grassfield-tiling
// The windows the reply of `hyprctl grassfield-tiling` lists as tiled in the place "fill" (Zoom is Fill, ADR-0036 D78: the
// Window menu says Unzoom for them, as for Hyprland's maximized mode), lower-case hex without 0x, a malformed one left out;
// null when the reply is malformed.
function parseFilled(text) {
    let msg = null;
    try {
        msg = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "tiling" || !Array.isArray(msg.outputs))
        return null;
    const out = [];
    for (const o of msg.outputs) {
        for (const w of (o && Array.isArray(o.windows) ? o.windows : [])) {
            const address = w && w.state === "tiled" && w.place === "fill" ? hexAddress(w.address) : "";
            if (address !== "")
                out.push(address);
        }
    }
    return out;
}

// Window `address` (any address form) is filled: it is among `filled` (parseFilled; null or [] when not known: it is not).
function isFilled(filled, address) {
    const a = hexAddress(address);
    return a !== "" && (filled || []).indexOf(a) >= 0;
}

// The Split View Desktop of `splits` (parseSplits) whose workspace is `workspace`, or null.
function splitOfWorkspace(splits, workspace) {
    return (splits || []).find(d => d.workspace === workspace) || null;
}

// The Split View Desktop of `splits` window `address` (any address form) is a member of, or null (ADR-0036 D52: another
// window on that Desktop is none).
function splitOfWindow(splits, address) {
    const a = hexAddress(address);
    return a === "" ? null : (splits || []).find(d => d.windows.indexOf(a) >= 0) || null;
}

// Step 6e (ADR-0036 D73): window `address` is a member of a Split View Desktop and the plugin keeps its titlebar away
// (`away`: Capabilities.has("tiling-split-titles"); a plugin before 6e still draws the strip above a member): the Overview lays
// it out without a band.
function splitTitleAway(splits, address, away) {
    return away === true && splitOfWindow(splits, address) !== null;
}

// Step 6d (ADR-0036 D72): an Overview drop of window `address` on Desktop `spaceId`: refused onto a Split View Desktop (its
// halves are its members': macOS takes no window dropped on a full-screen space) and for a member (its place is its half; Move
// Window to Desktop is its way out).
function dropAllowed(splits, address, spaceId) {
    return splitOfWorkspace(splits, spaceId) === null && splitOfWindow(splits, address) === null;
}

// Step 6d (ADR-0036 D71): the Split View Desktop of window `address` holds two windows (Replace Tiled Window keeps the other).
function splitPair(splits, address) {
    const d = splitOfWindow(splits, address);
    return d !== null && d.windows.length === 2;
}

// Step 6d (ADR-0036 D71): whether an unsplit `how` may be sent: Exit Full Screen / Move Window to Desktop (none, "" or
// "desktop") always; Make Window Full Screen ("fullscreen") and Replace Tiled Window ("replace") only with the plugin's
// tiling-split-rows (`rows`: a plugin before 6d ignores the argument and would send the window home instead).
function unsplitAllowed(how, rows) {
    if (how === undefined || how === "" || how === "desktop")
        return true;
    return rows === true && (how === "fullscreen" || how === "replace");
}

// TL33, ADR-0036 D43 (#48 review, MAJOR 3): the windows to fill their Split View Desktop alone: each the one member of a
// Desktop of `splits` still waiting for its second window, unless its picker is pending (`pending`: the window the shell
// waits a suggestion for or shows the suggestions of, "" for none). Its picker dismissed, refused (over the polkit sheet,
// Search...), timed out or never fetched: it fills, never leaving a half empty.
function lonelyMembers(splits, pending) {
    const p = hexAddress(pending);
    return (splits || []).filter(d => d.waiting && d.windows.length === 1 && d.windows[0] !== p).map(d => d.windows[0]);
}

// TL33, ADR-0036 D48 (integrator nested pass of 1ee992e, MAJOR B): the picker of a Split View the shell did not start (a
// key, another client, a test): the reply's `suggestion` (parseSuggestion) when it is the one of a Split View Desktop of
// `splits` whose one member still waits for its second window, in the "left-right" layout; null otherwise, and for the
// picker the user dismissed (`declined`: {address, gen} of that suggestion, or null; that window fills instead; a later
// Split View of the same window has a new generation and its own picker).
function splitPicker(splits, suggestion, declined) {
    if (!suggestion || suggestion.layout !== "left-right")
        return null;
    const a = hexAddress(suggestion.address); // "" matches no member (parseSplits keeps valid addresses only)
    if (declined && hexAddress(declined.address) === a && declined.gen === suggestion.gen)
        return null;
    return (splits || []).some(d => d.waiting && d.windows.length === 1 && d.windows[0] === a) ? suggestion : null;
}

// The reply's suggestion is the one the shell awaits (TL28): of the generation of the notice it waits for (`wantedGen`, -1:
// none), for the window it asked about (`asked`: Compositor.suggestionAsked {address, until}, or null).
function answersAsked(wantedGen, asked, suggestion) {
    return wantedGen >= 0 && !!asked && !!suggestion && suggestion.gen === wantedGen && hexAddress(suggestion.address) === hexAddress(asked.address);
}

// The Split View picker a reply shows by itself (D48): splitPicker, unless the reply is the answer the shell awaits for its
// own ask (answersAsked). A notice names no window: within the deadline of an earlier ask (D68: 6 s) a new Split View's
// `placed` notice is taken as that ask's answer, and its picker must still show (integrator re-review of 29db357, MAJOR 1:
// a Split View made a few seconds after an earlier picker filled alone).
function replyPicker(wantedGen, asked, splits, suggestion, declined) {
    return answersAsked(wantedGen, asked, suggestion) ? null : splitPicker(splits, suggestion, declined);
}

// The Desktops `spaces` ([{id, ...}] in id order) as the shell lists them (TL33, ADR-0036 D41): each Split View Desktop of
// `splits` right after the Desktop it came from (in id order when there are several); one whose home is not among `spaces`
// stays where its id puts it. Every Desktop is listed once, whatever the reply says (a chain or a loop of homes, which the
// plugin never makes, keeps id order).
function desktopOrder(spaces, splits) {
    const ids = spaces.map(s => s.id);
    const homeOf = id => {
        const d = splitOfWorkspace(splits, id);
        return d && d.home !== id && ids.indexOf(d.home) >= 0 ? d.home : null;
    };
    const out = [];
    const emit = s => {
        if (out.indexOf(s) >= 0)
            return;
        out.push(s);
        for (const t of spaces) {
            if (homeOf(t.id) === s.id)
                emit(t);
        }
    };
    for (const s of spaces) {
        if (homeOf(s.id) === null)
            emit(s);
    }
    for (const s of spaces)
        emit(s);
    return out;
}

// The Desktops `spaces` (in the order shown) numbered as macOS numbers them (#48 review, MINOR 7): `split` for a Split View
// Desktop of `splits`, which takes no number (it is named after its apps), `number` the position among the others (1-based,
// 0 for a Split View Desktop). New objects; `spaces` is left as it is.
function numberDesktops(spaces, splits) {
    let n = 0;
    return spaces.map(s => {
        const split = splitOfWorkspace(splits, s.id) !== null;
        return Object.assign({}, s, {split: split, number: split ? 0 : ++n});
    });
}

// The members of the tile group of the window `address` (any address form) in `groups` (parseGroups), itself included, in
// the reply's order; [] for a window in no group or without groups (TL29: only a window in a group sends group_front).
function membersOf(groups, address) {
    const key = groups ? groups.groupOf[hexAddress(address)] : undefined;
    return key !== undefined ? groups.members[key].slice() : [];
}

// The members an Overview drop of the window `own` moves with it (TL29, D31): those of `members` (membersOf) on its Desktop,
// `windows` [{address, workspace (Hyprland's id: a special workspace is negative), parked (minimized or hidden)}]. A
// minimized or hidden member is on no Desktop and stays.
function groupMovers(own, members, windows) {
    const byAddress = {};
    for (const w of (Array.isArray(windows) ? windows : []))
        byAddress[hexAddress(w.address)] = w;
    const self = byAddress[hexAddress(own)];
    if (!self || !(self.workspace > 0))
        return [];
    return (Array.isArray(members) ? members : []).map(hexAddress).filter(a => {
        const w = byAddress[a];
        return a !== "" && a !== hexAddress(own) && w !== undefined && w.workspace === self.workspace && !w.parked;
    });
}

// The steps of the Dock menu's Show Tile Group (TL29, D30), in the order the shell sends them through its one dispatch
// channel: [{op: "space", id} | {op: "restore", address} | {op: "move", address, id} | {op: "activate", address} |
// {op: "focus", address} | {op: "groupFront", address}]. `own` is the app's window of the group, `members` the group
// (membersOf), `windows` [{address, workspace (a special workspace is negative), active (its workspace is shown),
// minimized}]. The group's Desktop (own's, else the first member's that is on one) is shown first, so that every restore
// lands there (a restore takes the Desktop its display shows); own comes back (a minimized one restored, one hidden with
// its app moved there), then the minimized members; the restores focus their window, so own takes the focus after them;
// the group comes forward last, own in front.
function tileGroupSteps(own, members, windows) {
    const byAddress = {};
    for (const w of (Array.isArray(windows) ? windows : []))
        byAddress[hexAddress(w.address)] = w;
    const me = hexAddress(own);
    const self = byAddress[me];
    if (!self)
        return [];
    const group = (Array.isArray(members) ? members : []).map(hexAddress).filter(a => a !== "" && byAddress[a] !== undefined);
    const anchor = self.workspace > 0 ? self : group.map(a => byAddress[a]).find(w => w.workspace > 0);
    const steps = [];
    if (anchor && !anchor.active)
        steps.push({op: "space", id: anchor.workspace});
    if (self.minimized)
        steps.push({op: "restore", address: me});
    else if (!(self.workspace > 0) && anchor)
        steps.push({op: "move", address: me, id: anchor.workspace});
    else if (!(self.workspace > 0))
        steps.push({op: "activate", address: me});
    for (const a of group) {
        if (a !== me && byAddress[a].minimized)
            steps.push({op: "restore", address: a});
    }
    steps.push({op: "focus", address: me}, {op: "groupFront", address: me});
    return steps;
}

// The Dock menu's Show Tile Group rows of an app (TL29): the groups `groups` (parseGroups) that hold one of the app's
// windows `addresses`, each once, in the order of the app's windows: [{group, members, own}] where `own` is the app's
// first window in that group (the one the row brings forward).
function tileGroupRows(addresses, groups) {
    const rows = [];
    if (!groups || !Array.isArray(addresses))
        return rows;
    for (const a of addresses) {
        const key = groups.groupOf[hexAddress(a)];
        if (key === undefined || rows.some(r => r.group === key))
            continue;
        rows.push({group: key, members: groups.members[key].slice(), own: hexAddress(a)});
    }
    return rows;
}
