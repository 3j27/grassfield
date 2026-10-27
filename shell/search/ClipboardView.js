.pragma library

// Search's Clipboard view (ADR-0034, docs/specs/clipboard.md CB-5 to CB-12 and CB-15): which items a query shows, the kind a
// row names, the keys, the row menu and where the selection goes after a delete. Pure functions, unit-tested
// (tests/unit/tst_clipboard.qml); Search.qml and SearchPanel.qml run them and translate what the user reads.

// Qt.Key_* and Qt.*Modifier values (a .pragma library sees no QML enums).
var KEY = {
    escape: 0x01000000,
    tab: 0x01000001,
    backtab: 0x01000002,
    backspace: 0x01000003,
    ret: 0x01000004,
    enter: 0x01000005,
    up: 0x01000013,
    down: 0x01000015,
    f10: 0x01000039,
    menu: 0x01000055,
    space: 0x20,
    four: 0x34,
    c: 0x43,
    p: 0x50,
    y: 0x59
};
var SHIFT = 0x02000000;
var CTRL = 0x04000000;
var ALT = 0x08000000;
var META = 0x10000000;

// The items a query shows, in the order the helper keeps them (pinned first, newest pin first, then newest copy first).
// matchIds: null for every item (an empty query), else the ids of the helper's search (the order of `items` is kept).
function visible(items, matchIds) {
    const list = Array.isArray(items) ? items : [];
    if (matchIds === null || matchIds === undefined)
        return list.slice();
    const wanted = {};
    for (const id of matchIds)
        wanted[id] = true;
    return list.filter(it => wanted[it.id] === true);
}

// What a row says its item is: "formatted" (text with HTML or RTF), "text", "image", "files" (one) or "items" (several
// files, "%n Items").
function kindKey(item) {
    if (!item)
        return "text";
    if (item.kind === "image")
        return "image";
    if (item.kind === "files")
        return (Number(item.files) || 0) > 1 ? "items" : "files";
    return item.formatted === true ? "formatted" : "text";
}

// The image format a row names ("PNG image"), from the item's MIME types; "" when none is known.
function imageFormat(item) {
    const mimes = item && Array.isArray(item.mimes) ? item.mimes : [];
    if (mimes.indexOf("image/png") >= 0)
        return "PNG";
    if (mimes.indexOf("image/jpeg") >= 0)
        return "JPEG";
    if (mimes.indexOf("image/webp") >= 0)
        return "WebP";
    return "";
}

// Whether "Paste as Plain Text" means something for the item: text that has a formatted part.
function hasPlainVariant(item) {
    return !!item && item.kind === "text" && item.formatted === true;
}

// A key in the field while the Clipboard view is shown (the keyboard table of docs/specs/clipboard.md). Returns the action:
// paste, pastePlain, copy, pin, menu, delete, preview, leave, up, down, escape, more, or "" (the field handles the key: typing,
// a selected query text copied with Ctrl+C, the caret).
function keyAction(key, modifiers, fieldEmpty, fieldHasSelection) {
    const mods = Number(modifiers) & (SHIFT | CTRL | ALT | META);
    const shift = (mods & SHIFT) !== 0;
    switch (key) {
    case KEY.ret:
    case KEY.enter:
        if (mods === 0)
            return "paste";
        return mods === SHIFT ? "pastePlain" : "";
    case KEY.up:
        return mods === 0 ? "up" : "";
    case KEY.down:
        return mods === 0 ? "down" : "";
    case KEY.escape:
        return "escape";
    case KEY.tab:
        return shift ? "" : "more";
    case KEY.c:
        return mods === CTRL && !fieldHasSelection ? "copy" : "";
    case KEY.p:
        return mods === CTRL ? "pin" : "";
    case KEY.y:
        return mods === CTRL ? "preview" : "";
    case KEY.menu:
        return mods === 0 ? "menu" : "";
    case KEY.f10:
        return mods === SHIFT ? "menu" : "";
    case KEY.space:
        return mods === 0 && fieldEmpty ? "preview" : "";
    case KEY.backspace:
        if (!fieldEmpty)
            return "";
        if (mods === CTRL)
            return "delete";
        return mods === 0 ? "leave" : "";
    }
    return "";
}

// Whether a key opens the Clipboard view from Search's results view: ⌘4 (Super+4, forwarded as Ctrl+4) in the field.
function opensView(key, modifiers) {
    const mods = Number(modifiers) & (SHIFT | CTRL | ALT | META);
    return key === KEY.four && (mods === CTRL || mods === META);
}

// The selection after the row at `index` was deleted from a list of `count` rows (before the delete): the next row, or the
// new last one; -1 when the list is empty.
function selectionAfterRemove(count, index) {
    const left = Math.max(0, Number(count) - 1);
    if (left === 0)
        return -1;
    return Math.max(0, Math.min(Number(index), left - 1));
}

// The row menu (macOS 26.0: Paste, Copy, Delete Item; Grassfield adds Paste as Plain Text for formatted text, and Pin or
// Unpin). Ids only: SearchPanel.qml names them.
function menuIds(item) {
    if (!item)
        return [];
    const ids = ["paste"];
    if (hasPlainVariant(item))
        ids.push("pastePlain");
    ids.push("copy", "-", item.pinned === true ? "unpin" : "pin", "-", "delete");
    return ids;
}
