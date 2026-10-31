.pragma library

// Menu shortcut labels (owner decision 2026-10-26, ADR-0024 C-8). Menus hold a shortcut as text ("Ctrl+Shift+N", "Super+L",
// with translated key names: "Ctrl+Maj+N") and show it in the style of the device: the text itself on a PC, the macOS symbols
// on a Mac ("⌃⇧N", "⌘L"). Pure functions, no I/O: the host reads the device facts and the `keyboard.shortcutStyle` setting.
// apps/shortcutstyle.h is the C++ copy of macDevice() and style() for Files and Preview.

const STYLES = ["automatic", "mac", "pc"];

// The modifiers in the macOS order (Control, Option, Shift, Command), with the names the menus use, English and translated
// (lower case). Super plays Command (ADR-0002).
const MODIFIERS = [
    {symbol: "⌃", names: ["ctrl", "control", "strg"]},
    {symbol: "⌥", names: ["alt", "option", "opt"]},
    {symbol: "⇧", names: ["shift", "maj"]},
    {symbol: "⌘", names: ["super", "meta", "win", "cmd", "command"]}
];

// Keys macOS draws as symbols (lower case, English and French names of the catalog). Other keys keep their name, letters
// are upper case.
const KEYS = {
    "left": "←", "gauche": "←",
    "right": "→", "droite": "→",
    "up": "↑", "haut": "↑",
    "down": "↓", "bas": "↓",
    "return": "↩", "enter": "↩", "entrée": "↩",
    "backspace": "⌫", "retour arrière": "⌫",
    "del": "⌦", "delete": "⌦", "suppr": "⌦",
    "esc": "⎋", "escape": "⎋", "échap": "⎋",
    "tab": "⇥",
    "pageup": "⇞", "page préc.": "⇞",
    "pagedown": "⇟", "page suiv.": "⇟",
    "home": "↖", "début": "↖",
    "end": "↘", "fin": "↘"
};

function normalizeStyle(setting) {
    return STYLES.indexOf(setting) >= 0 ? setting : "automatic";
}

// The device is a Mac: Apple hardware (`sysVendor`, the firmware's /sys/class/dmi/id/sys_vendor) or an Apple keyboard among
// the input devices (`inputDevices`, the text of /proc/bus/input/devices: a block with the USB vendor 05ac, or the Bluetooth
// vendor 004c on bus 0005, whose handlers include "kbd").
function macDevice(sysVendor, inputDevices) {
    if (String(sysVendor || "").trim() === "Apple Inc.")
        return true;
    const blocks = String(inputDevices || "").split(/\n\s*\n/);
    for (let i = 0; i < blocks.length; i++) {
        const b = blocks[i];
        const apple = /\bVendor=05ac\b/i.test(b) || (/\bBus=0005\b/.test(b) && /\bVendor=004c\b/i.test(b));
        if (apple && /^H: Handlers=.*\bkbd\b/m.test(b))
            return true;
    }
    return false;
}

// "mac" or "pc" for a setting and the device.
function style(setting, mac) {
    const s = normalizeStyle(setting);
    if (s !== "automatic")
        return s;
    return mac ? "mac" : "pc";
}

// The label of a shortcut text in a style: unchanged for "pc" (and for anything that is not a shortcut), the macOS form for
// "mac" (modifiers as symbols in the macOS order, then the key, no separators).
function label(text, styleName) {
    const t = String(text || "");
    if (styleName !== "mac" || t === "")
        return t;
    const parts = t.split("+");
    // "Ctrl++": the key is the plus sign (split leaves two empty parts at the end).
    if (parts.length >= 3 && parts[parts.length - 1] === "" && parts[parts.length - 2] === "") {
        parts.splice(parts.length - 2, 2, "+");
    }
    const key = parts.pop();
    const mods = [false, false, false, false];
    for (let i = 0; i < parts.length; i++) {
        const name = parts[i].trim().toLowerCase();
        const m = MODIFIERS.findIndex(mod => mod.names.indexOf(name) >= 0);
        if (m < 0)
            return t; // not a shortcut this function knows: shown as written
        mods[m] = true;
    }
    let out = "";
    for (let i = 0; i < MODIFIERS.length; i++) {
        if (mods[i])
            out += MODIFIERS[i].symbol;
    }
    const k = key.trim();
    const symbol = KEYS[k.toLowerCase()];
    return out + (symbol !== undefined ? symbol : (k.length === 1 ? k.toUpperCase() : k));
}
