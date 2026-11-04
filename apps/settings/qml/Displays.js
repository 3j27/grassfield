.pragma library

// Settings > Displays (ADR-0031): the state the shell publishes, the choices of the pane, and the lines of displays.conf and of a
// trial (the rule of config/hypr/grassfield/displays.lua, checked again in C++ by systemguard.h::isDisplayLine). Pure functions,
// unit-tested (tests/unit/tst_settingsdisplays.qml).

// The scales the resolution choices are made of: Hyprland takes a scale whose logical size is a whole number of pixels.
var SCALES = [1, 1.25, 1.333333, 1.5, 1.6, 1.666667, 1.75, 2, 2.4, 2.5, 3];
// At most this many resolution choices, as macOS ("Larger Text", two between, "Default", "More Space").
var MAX_CHOICES = 5;
// The span of the choices around the default, as macOS's: the most space about 1.25 times the default's room, the largest text
// about 1.3 times the default's size.
var MORE_SPACE_RATIO = 1.25;
var LARGER_TEXT_RATIO = 1.3;
// The narrowest logical width offered (a smaller one leaves no room for the menu bar's items and a window).
var MIN_LOGICAL_WIDTH = 1024;

function num(v) {
    return typeof v === "number" && isFinite(v) ? v : 0;
}

// "2880x1800@120.00Hz" -> {w, h, hz}, or null.
function parseMode(s) {
    const m = /^(\d{1,5})x(\d{1,5})@(\d{1,4}(?:\.\d{1,3})?)(?:Hz)?$/.exec(String(s));
    return m ? {w: parseInt(m[1], 10), h: parseInt(m[2], 10), hz: parseFloat(m[3])} : null;
}

// The state file's text (shell/platform/DisplaysFile.js) -> {monitors, backlight, trial}, or null when it is not one.
function parseState(text) {
    let j;
    try {
        j = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!j || j.v !== 1 || !Array.isArray(j.monitors))
        return null;
    const monitors = j.monitors.filter(m => m && typeof m.name === "string" && m.name !== "" && !m.disabled).map(m => ({
        name: m.name, description: typeof m.description === "string" ? m.description : "", make: String(m.make || ""), model: String(m.model || ""), serial: String(m.serial || ""),
        width: num(m.width), height: num(m.height), refreshRate: num(m.refreshRate), x: num(m.x), y: num(m.y), scale: num(m.scale) || 1,
        transform: num(m.transform), physicalWidth: num(m.physicalWidth), physicalHeight: num(m.physicalHeight),
        modes: (Array.isArray(m.availableModes) ? m.availableModes : []).map(parseMode).filter(x => x !== null)}));
    const light = j.backlight && typeof j.backlight.device === "string" && j.backlight.device !== "" ? {device: j.backlight.device, level: Math.max(0, Math.min(1, num(j.backlight.level)))} : null;
    const trial = j.trial && typeof j.trial.id === "string" ? {id: j.trial.id, state: String(j.trial.state)} : null;
    return {monitors: monitors, backlight: light, trial: trial};
}

// A laptop's own panel (eDP, LVDS, DSI): macOS calls it "Built-in Display".
function isBuiltIn(m) {
    return /^(eDP|LVDS|DSI)-/.test(String(m.name));
}

// The pixels the monitor runs at (its mode, before the scale and the rotation).
function rotated(m) {
    return m.transform % 2 === 1;
}

// Hyprland's own default for a panel (its "auto" scale): 2 above 200 pixels per inch, 1.5 above 140, else 1. Without a physical
// size, 1.
function defaultScale(m) {
    const mmW = m.physicalWidth, mmH = m.physicalHeight;
    if (mmW <= 0 || mmH <= 0)
        return 1;
    const inches = Math.sqrt(mmW * mmW + mmH * mmH) / 25.4;
    const ppi = Math.sqrt(m.width * m.width + m.height * m.height) / inches;
    return ppi > 200 ? 2 : ppi > 140 ? 1.5 : 1;
}

function whole(v) {
    return Math.abs(v - Math.round(v)) < 0.01;
}

// The resolution choices of a monitor, largest text first: [{scale, width, height (logical), isDefault}]. The scales whose
// logical size is whole and at least MIN_LOGICAL_WIDTH wide, within the span around the default; the default and the monitor's own
// scale always in; at most MAX_CHOICES, the ends and the default kept, then the scales closest to the default.
function scaleChoices(m) {
    const def = defaultScale(m);
    const fits = s => whole(m.width / s) && whole(m.height / s) && Math.round(m.width / s) >= MIN_LOGICAL_WIDTH;
    let list = SCALES.filter(s => s >= 1 && s >= def / MORE_SPACE_RATIO - 1e-6 && s <= def * LARGER_TEXT_RATIO + 1e-6 && fits(s));
    for (const s of [def, m.scale]) {
        if (!list.some(x => Math.abs(x - s) < 1e-3))
            list.push(s);
    }
    list.sort((a, b) => b - a);
    if (list.length > MAX_CHOICES) {
        const keep = [list[0], list[list.length - 1], def, m.scale];
        const rest = list.filter(s => keep.indexOf(s) < 0).sort((a, b) => Math.abs(a - def) - Math.abs(b - def));
        for (const s of rest) {
            if (keep.filter((v, i) => keep.indexOf(v) === i).length >= MAX_CHOICES)
                break;
            keep.push(s);
        }
        list = list.filter(s => keep.indexOf(s) >= 0);
    }
    return list.map(s => ({scale: s, width: Math.round(m.width / s), height: Math.round(m.height / s), isDefault: Math.abs(s - def) < 1e-3}));
}

// The index of the choice nearest to the monitor's scale.
function currentChoice(choices, scale) {
    let best = -1, d = Infinity;
    for (let i = 0; i < choices.length; i++) {
        const di = Math.abs(choices[i].scale - scale);
        if (di < d) {
            d = di;
            best = i;
        }
    }
    return best;
}

// The refresh rates of the monitor's current resolution, highest first, as whole or two-decimal numbers.
function refreshRates(m) {
    const seen = {};
    const out = [];
    for (const mode of m.modes) {
        const key = mode.hz.toFixed(2);
        if (mode.w === m.width && mode.h === m.height && !seen[key]) {
            seen[key] = true;
            out.push(mode.hz);
        }
    }
    return out.sort((a, b) => b - a);
}

// "120 Hz", "59.94 Hz": the number in the language's format ("59,94 Hz" in French); `locale` defaults to the UI's.
function hzLabel(hz, locale) {
    const r = Math.round(hz);
    const whole = Math.abs(hz - r) < 0.05;
    return qsTr("%1 Hz").arg((locale || Qt.locale()).toString(whole ? r : hz, "f", whole ? 0 : 2));
}

function scaleText(s) {
    return String(Math.round(s * 1e6) / 1e6);
}

function rateText(hz) {
    return hz.toFixed(2);
}

// The description the line names, or "" when the display cannot be named that way (no description, a control character, too
// long): such a display is shown but not changed.
function descOf(m) {
    const d = String(m.description);
    // Its length in UTF-8 bytes: each %XX of the URI encoding is one byte.
    const bytes = encodeURIComponent(d).replace(/%[0-9A-F]{2}/g, "x").length;
    return d !== "" && !/[\x00-\x1f\x7f]/.test(d) && bytes <= 160 ? d : "";
}

// One line of displays.conf for a monitor with some fields changed ({scale, hz, x, y, transform}), or "" when the display
// cannot be named.
function lineFor(m, change) {
    const c = change || {};
    const desc = descOf(m);
    if (desc === "")
        return "";
    const hz = c.hz !== undefined ? c.hz : m.refreshRate;
    const x = c.x !== undefined ? c.x : m.x, y = c.y !== undefined ? c.y : m.y;
    const scale = c.scale !== undefined ? c.scale : m.scale;
    const transform = c.transform !== undefined ? c.transform : m.transform;
    return ["v1", "desc:" + desc, m.width + "x" + m.height + "@" + rateText(hz), Math.round(x) + "x" + Math.round(y), scaleText(scale), String(transform)].join("\t");
}

// The description a line names ("" when it is not a line).
function descOfLine(line) {
    const f = String(line).split("\t");
    return f.length === 6 && f[1].indexOf("desc:") === 0 ? f[1].slice(5) : "";
}

// The lines of a trial: the kept lines of the other displays, then the new lines (one per changed display).
function mergeLines(kept, fresh) {
    const changed = {};
    for (const l of fresh)
        changed[descOfLine(l)] = true;
    return kept.filter(l => !changed[descOfLine(l)]).concat(fresh);
}

// A trial id: 8 letters and digits.
function trialId(random) {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    let id = "";
    for (let i = 0; i < 8; i++)
        id += chars[Math.floor(random() * chars.length) % chars.length];
    return id;
}

// The logical size of a monitor in the layout (its pixels over its scale, turned with its rotation).
function logicalSize(m) {
    const w = Math.round(m.width / m.scale), h = Math.round(m.height / m.scale);
    return rotated(m) ? {w: h, h: w} : {w: w, h: h};
}

// Arrangement: the monitor `moved` dropped at (x, y) in layout pixels, snapped against `other` so that the two touch along a whole
// edge side (left, right, above or below, whichever is nearest), the free coordinate clamped so that they overlap. Returns {x, y}.
function snapBeside(moved, x, y, other) {
    const a = logicalSize(moved), b = logicalSize(other);
    const cx = x + a.w / 2, cy = y + a.h / 2, ox = other.x + b.w / 2, oy = other.y + b.h / 2;
    const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
    if (Math.abs(cx - ox) / (a.w + b.w) >= Math.abs(cy - oy) / (a.h + b.h)) {
        const nx = cx < ox ? other.x - a.w : other.x + b.w;
        return {x: Math.round(nx), y: Math.round(clamp(y, other.y - a.h + 1, other.y + b.h - 1))};
    }
    const ny = cy < oy ? other.y - a.h : other.y + b.h;
    return {x: Math.round(clamp(x, other.x - a.w + 1, other.x + b.w - 1)), y: Math.round(ny)};
}
