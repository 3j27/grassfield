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
