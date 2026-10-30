.pragma library

// Client side of menu/1, the grassfield-menu-bridge socket protocol (ADR-0008, docs/specs/menu-bridge.md), and of
// the gfc/1 `appmenu` events it relays. Pure functions, unit-tested by tests/unit/tst_menubridge.qml.
//
// Data coming from the plugin and from the bridge (which relays applications' menus) is untrusted: every field is
// type-checked, strings are capped, trees are depth- and size-limited before they reach the menu bar.

var protocol = "menu/1";

var limits = {
    line: 4 * 1024 * 1024, // characters of one bridge line
    depth: 8,              // menu levels below the root
    items: 2000,           // items in one menu tree
    label: 256,            // characters of a label
    key: 32,               // characters of one shortcut key name
    keys: 6,               // keys of one shortcut
    code: 64,              // characters of an error code
    message: 256,          // characters of an error message
    launcherCount: 99999,  // largest badge count of a launcher message
    launcherApps: 64,      // apps whose launcher state is kept
    inhibitors: 1024,      // largest cookie count of a screensaver message
    // The bridge repeats its screensaver line every 20 s (ScreenSaver.h kHeartbeatMs); after three missed beats the shell
    // drops "inhibited" (a bridge that hangs without exiting must not hold the idle lock off).
    screensaverStaleMs: 60000
};

// Validated lowercase hex of a Hyprland window address ("0x" prefix optional), "" if invalid.
function normalizeAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

// D-Bus bus name (unique ":1.42" or well-known "org.kde.Foo"), the plugin's rules (FR19).
function isBusName(name) {
    if (typeof name !== "string" || name.length === 0 || name.length > 255)
        return false;
    if (name[0] === ":")
        return /^:[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$/.test(name);
    return /^[A-Za-z_-][A-Za-z0-9_-]*(\.[A-Za-z_-][A-Za-z0-9_-]*)+$/.test(name);
}

// D-Bus object path: "/" or "/"-separated non-empty [A-Za-z0-9_] elements.
function isObjectPath(path) {
    return typeof path === "string" && path.length <= 255 && /^\/([A-Za-z0-9_]+(\/[A-Za-z0-9_]+)*)?$/.test(path);
}

function isPid(pid) {
    return Number.isInteger(pid) && pid > 0 && pid <= 2147483647;
}

// gfc/1 keyboard-focus event data (feature keyboard-focus: the seat's keyboard entered a mapped window) -> the window's
// normalized address, or null when it is not a valid keyboard-focus event. A chosen item's action waits for it (MB12).
function parseKeyboardFocusEvent(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || typeof msg !== "object" || msg.v !== "gfc/1" || msg.type !== "keyboard-focus" || typeof msg.address !== "string")
        return null;
    const address = normalizeAddress(msg.address);
    return address === "" ? null : address;
}

// gfc/1 appmenu event data -> {address, service, path, pid}, or null when it is not a valid appmenu event.
// An empty service and path means the window has no (more) set_address menu; its pid is then the window's Wayland
// client (0 for an X11/XWayland window or a clear): the bridge may serve it a menu that process registered with
// com.canonical.AppMenu.Registrar (Electron, ADR-0008 amendment 2026-10-25).
function parseAppmenuEvent(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || typeof msg !== "object" || msg.v !== "gfc/1" || msg.type !== "appmenu")
        return null;
    const address = normalizeAddress(msg.address);
    if (address === "" || typeof msg.service !== "string" || typeof msg.path !== "string")
        return null;
    if (msg.service === "" && msg.path === "")
        return {address: address, service: "", path: "", pid: isPid(msg.pid) ? msg.pid : 0};
    if (!isBusName(msg.service) || !isObjectPath(msg.path))
        return null;
    return {address: address, service: msg.service, path: msg.path, pid: isPid(msg.pid) ? msg.pid : 0};
}

// ---- shell -> bridge lines ("" when an argument is invalid: nothing is sent) ----

function helloLine(appmenu) {
    return JSON.stringify({type: "hello", v: protocol, appmenu: appmenu === true}) + "\n";
}

// The registration must carry the registering client's pid (the bridge checks the bus name against it).
function openLine(address, reg) {
    const window = normalizeAddress(address);
    if (window === "" || !reg || !isBusName(reg.service) || !isObjectPath(reg.path) || !isPid(reg.pid))
        return "";
    return JSON.stringify({type: "open", window: window, service: reg.service, path: reg.path, pid: reg.pid}) + "\n";
}

// A window without a set_address menu whose Wayland client is pid `pid`: the menu that process registered with the
// registrar (ADR-0008 amendment 2026-10-25).
function openRegisteredLine(address, pid) {
    const window = normalizeAddress(address);
    if (window === "" || !isPid(pid))
        return "";
    return JSON.stringify({type: "open-registered", window: window, pid: pid}) + "\n";
}

function itemLine(type, address, id) {
    const window = normalizeAddress(address);
    if ((type !== "about-to-show" && type !== "activate") || window === "" || !Number.isInteger(id) || id < 0 || id > 2147483647)
        return "";
    return JSON.stringify({type: type, window: window, id: id}) + "\n";
}

function closeLine(address) {
    const window = normalizeAddress(address);
    return window === "" ? "" : JSON.stringify({type: "close", window: window}) + "\n";
}

// ---- bridge -> shell ----

// Plain, single-line text of at most `max` characters (no control or bidirectional formatting characters).
function plainText(value, max) {
    if (typeof value !== "string")
        return "";
    const cleaned = value.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ").replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "").replace(/\s+/g, " ").trim();
    return cleaned.length > max ? cleaned.slice(0, max) : cleaned;
}

function sanitizeShortcut(value) {
    if (!Array.isArray(value))
        return [];
    const out = [];
    for (let i = 0; i < value.length && out.length < 4; i++) {
        const keys = value[i];
        if (!Array.isArray(keys) || keys.length === 0 || keys.length > limits.keys)
            continue;
        if (keys.every(k => typeof k === "string" && k.length > 0 && k.length <= limits.key && /^[^\s\u0000-\u001f\u007f-\u009f]+$/.test(k)))
            out.push(keys.slice());
    }
    return out;
}

// menu/1 items -> validated items {id, type, label, enabled, visible, toggleType, toggleState, shortcut, submenu,
// children}. `budget` = {items: n} is shared by the whole tree; invalid entries are dropped.
function sanitizeItems(items, depth, budget) {
    const out = [];
    if (!Array.isArray(items) || depth >= limits.depth)
        return out;
    for (let i = 0; i < items.length; i++) {
        if (budget.items <= 0)
            break;
        const it = items[i];
        if (!it || typeof it !== "object" || !Number.isInteger(it.id) || it.id < 0 || it.id > 2147483647)
            continue;
        budget.items--;
        const separator = it.type === "separator";
        const toggleType = it["toggle-type"] === "checkmark" || it["toggle-type"] === "radio" ? it["toggle-type"] : "";
        const submenu = !separator && it.submenu === true;
        out.push({
            id: it.id,
            type: separator ? "separator" : "standard",
            label: separator ? "" : plainText(it.label, limits.label),
            enabled: it.enabled !== false,
            visible: it.visible !== false,
            toggleType: toggleType,
            toggleState: toggleType !== "" && (it["toggle-state"] === 0 || it["toggle-state"] === 1) ? it["toggle-state"] : -1,
            shortcut: separator ? [] : sanitizeShortcut(it.shortcut),
            submenu: submenu,
            children: submenu ? sanitizeItems(it.children, depth + 1, budget) : []
        });
    }
    return out;
}

// One bridge line -> {type: "status", state, registrar} | {type: "menu", window, revision, items}
// | {type: "launcher", app, count, progress, urgent} | {type: "screensaver", inhibited, count}
// | {type: "error", window, code, message}, or null.
function parseBridgeLine(line) {
    if (typeof line !== "string" || line.length === 0 || line.length > limits.line)
        return null;
    let msg = null;
    try {
        msg = JSON.parse(line);
    } catch (e) {
        return null;
    }
    if (!msg || typeof msg !== "object")
        return null;
    switch (msg.type) {
    case "status":
        if (msg.v !== protocol)
            return null;
        return {type: "status", state: plainText(msg.state, limits.code), registrar: msg.registrar === true};
    case "menu": {
        const window = normalizeAddress(msg.window);
        if (window === "" || !Number.isInteger(msg.revision) || msg.revision < 0 || !Array.isArray(msg.items))
            return null;
        return {type: "menu", window: window, revision: msg.revision, items: sanitizeItems(msg.items, 0, {items: limits.items})};
    }
    case "launcher": {
        // ADR-0018: an application's own badge, progress and attention hint. null = this update did not touch it.
        if (typeof msg.app !== "string" || !/^[A-Za-z0-9._-]{1,255}$/.test(msg.app))
            return null;
        const count = msg.count === null || msg.count === undefined ? null : msg.count;
        const progress = msg.progress === null || msg.progress === undefined ? null : msg.progress;
        const urgent = msg.urgent === null || msg.urgent === undefined ? null : msg.urgent;
        if (count !== null && (!Number.isInteger(count) || count < 0 || count > limits.launcherCount))
            return null;
        if (progress !== null && (typeof progress !== "number" || !isFinite(progress) || progress < -1 || progress > 1))
            return null;
        if (urgent !== null && typeof urgent !== "boolean")
            return null;
        return {type: "launcher", app: msg.app, count: count, progress: progress, urgent: urgent};
    }
    case "screensaver":
        // GF-016: applications hold org.freedesktop.ScreenSaver idle inhibitors (the idle lock waits while true).
        if (typeof msg.inhibited !== "boolean" || !Number.isInteger(msg.count) || msg.count < 0 || msg.count > limits.inhibitors)
            return null;
        return {type: "screensaver", inhibited: msg.inhibited, count: msg.count};
    case "error":
        return {
            type: "error",
            window: normalizeAddress(msg.window),
            code: /^[a-z][a-z-]{0,63}$/.test(String(msg.code)) ? msg.code : "unknown",
            message: plainText(msg.message, limits.message)
        };
    }
    return null;
}

// ---- launcher state (ADR-0018) ----

// Latest state per app (lower-case desktop id): {count?: int, progress?: 0..1, urgent: bool}. `state` is not changed;
// `msg` is a parsed launcher line. A count (0 included) means the app owns its badge; progress -1 removes the bar;
// a line with nothing in it forgets the app (its sender left the bus). At most limits.launcherApps apps are kept.
function applyLauncher(state, msg) {
    const id = String(msg.app).toLowerCase();
    const next = Object.assign({}, state);
    if (msg.count === null && msg.progress === null && msg.urgent === null) {
        delete next[id];
        return next;
    }
    if (next[id] === undefined && Object.keys(next).length >= limits.launcherApps)
        return state;
    const entry = Object.assign({urgent: false}, next[id]);
    if (msg.count !== null)
        entry.count = msg.count;
    if (msg.progress !== null) {
        if (msg.progress < 0)
            delete entry.progress;
        else
            entry.progress = msg.progress;
    }
    if (msg.urgent !== null)
        entry.urgent = msg.urgent;
    next[id] = entry;
    return next;
}

// Error codes after which the window's current bridge menu must not stay on screen (its items would be dead):
// the application's menu was refused at open (pid-mismatch, no-owner, backoff, foreign-namespace), left the bus (gone),
// could not be read again (layout-failed) or was refused as too large when re-read (oversized). The window falls back
// to T0.
var menuLostCodes = ["pid-mismatch", "no-owner", "gone", "layout-failed", "oversized", "backoff", "foreign-namespace"];

function menuLost(code) {
    return menuLostCodes.indexOf(code) >= 0;
}

// ---- menu bar models ----

// Top-level menus shown in the bar after the app name: [{dbusId, title, enabled}] (visible, labeled, not separators).
function topLevel(items) {
    const out = [];
    if (!Array.isArray(items))
        return out;
    for (let i = 0; i < items.length; i++) {
        const it = items[i];
        if (it.visible && it.type !== "separator" && it.label !== "")
            out.push({dbusId: it.id, title: it.label, enabled: it.enabled});
    }
    return out;
}

// The item with this id anywhere in the tree, or null.
function findItem(items, id) {
    if (!Array.isArray(items))
        return null;
    for (let i = 0; i < items.length; i++) {
        if (items[i].id === id)
            return items[i];
        const inner = findItem(items[i].children, id);
        if (inner)
            return inner;
    }
    return null;
}

// Shortcut text as the menus show it ("Ctrl+Shift+N", in French "Ctrl+Maj+N"); the first shortcut only. The key names are the
// ones the shell's own menus carry (they are translated: AppMenuModel's shortcuts, MenuShortcut.js maps the same names to the
// macOS symbols on a Mac), so an application's shortcut and the shell's look the same. A key the table does not know keeps the
// name the application sent.
function keyName(k) {
    switch (k) {
    case "Control":
        return qsTr("Ctrl");
    case "Shift":
        return qsTr("Shift");
    case "Alt":
        return qsTr("Alt");
    case "Super":
        return qsTr("Super");
    case "plus":
        return "+";
    case "minus":
        return "-";
    case "space":
        return qsTr("Space");
    case "Return":
        return qsTr("Enter");
    case "Delete":
        return qsTr("Del");
    case "BackSpace":
        return qsTr("Backspace");
    case "Escape":
        return qsTr("Esc");
    case "Tab":
        return qsTr("Tab");
    case "Left":
        return qsTr("Left");
    case "Right":
        return qsTr("Right");
    case "Up":
        return qsTr("Up");
    case "Down":
        return qsTr("Down");
    case "Home":
        return qsTr("Home");
    case "End":
        return qsTr("End");
    case "Page_Up":
    case "Prior":
        return qsTr("PageUp");
    case "Page_Down":
    case "Next":
        return qsTr("PageDown");
    }
    return k.length === 1 ? k.toUpperCase() : k;
}

function shortcutText(shortcut) {
    if (!Array.isArray(shortcut) || shortcut.length === 0)
        return "";
    return shortcut[0].map(keyName).join("+");
}

// PopupMenu model of a menu's children: [{id: "bridge", dbusId, text, shortcut, enabled, checked, separator?,
// submenu?}]. Hidden items are left out (the application hid them); separators never lead, trail or repeat. A submenu
// the application has not filled (yet) stays visible but disabled.
function popupModel(children) {
    const out = [];
    if (!Array.isArray(children))
        return out;
    for (let i = 0; i < children.length; i++) {
        const it = children[i];
        if (!it.visible)
            continue;
        if (it.type === "separator") {
            if (out.length > 0 && !out[out.length - 1].separator)
                out.push({separator: true});
            continue;
        }
        const entry = {
            id: "bridge",
            dbusId: it.id,
            text: it.label,
            shortcut: shortcutText(it.shortcut),
            enabled: it.enabled,
            checked: it.toggleType !== "" && it.toggleState === 1
        };
        if (it.submenu) {
            const sub = popupModel(it.children);
            if (sub.length > 0)
                entry.submenu = sub;
            else
                entry.enabled = false;
        }
        out.push(entry);
    }
    while (out.length > 0 && out[out.length - 1].separator)
        out.pop();
    return out;
}
