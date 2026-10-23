.pragma library

// Pure navigation helpers of Grassfield Files (unit tested in tests/unit/tst_filesnav.qml).

// Next index in an icon grid of `columns` per row. `key`: "left" | "right" | "up" | "down" | "home" |
// "end" | "pageup" | "pagedown". `pageRows` rows per page. With no current item (-1) any move
// selects the first item. Returns `current` when the move leaves the grid.
function gridMove(current, key, columns, count, pageRows) {
    if (count <= 0)
        return -1;
    const cols = Math.max(1, columns);
    if (current < 0 || current >= count)
        return key === "end" ? count - 1 : 0;
    const page = Math.max(1, pageRows) * cols;
    switch (key) {
    case "left":
        return Math.max(0, current - 1);
    case "right":
        return Math.min(count - 1, current + 1);
    case "up":
        return current - cols >= 0 ? current - cols : current;
    case "down":
        if (current + cols < count)
            return current + cols;
        // From a full row into a shorter last row: land on its last item.
        return Math.floor(current / cols) < Math.floor((count - 1) / cols) ? count - 1 : current;
    case "home":
        return 0;
    case "end":
        return count - 1;
    case "pageup":
        return Math.max(current % cols, current - page);
    case "pagedown":
        return Math.min(count - 1, current + page);
    }
    return current;
}

// Next index in a single-column list (list view, column view).
function listMove(current, key, count, pageRows) {
    switch (key) {
    case "left":
    case "right":
        return current;
    }
    return gridMove(current, key, 1, count, pageRows);
}

// Next index in the gallery view's thumbnail strip (one horizontal row): Left/Right move by one, Home/End to the
// ends, PageUp/PageDown by `pageItems` (the thumbnails in view); Up/Down do not move. With no current item any move
// selects the first item (End the last).
function stripMove(current, key, count, pageItems) {
    if (count <= 0)
        return -1;
    if (current < 0 || current >= count)
        return key === "end" ? count - 1 : 0;
    const page = Math.max(1, pageItems);
    switch (key) {
    case "left":
        return Math.max(0, current - 1);
    case "right":
        return Math.min(count - 1, current + 1);
    case "home":
        return 0;
    case "end":
        return count - 1;
    case "pageup":
        return Math.max(0, current - page);
    case "pagedown":
        return Math.min(count - 1, current + page);
    }
    return current;
}

// View modes in toolbar, menu and shortcut order (Ctrl+1 .. Ctrl+4).
const viewModes = ["icons", "list", "columns", "gallery"];

// A saved or requested mode, or "icons" when it is not one of viewModes.
function normalizeViewMode(mode) {
    return viewModes.indexOf(String(mode)) >= 0 ? String(mode) : "icons";
}

// Mode of the Ctrl+<number> shortcut (1-based), "" for another number.
function viewModeForShortcut(number) {
    return number >= 1 && number <= viewModes.length ? viewModes[number - 1] : "";
}

// The view that draws a tab: its mode, except that tag search results (a flat list of files from several folders)
// have no folder columns and show as a list in the column mode.
function effectiveView(mode, isSearch) {
    const m = normalizeViewMode(mode);
    return isSearch && m === "columns" ? "list" : m;
}

// The gallery shows one item: when nothing is current yet (folder just listed), the first item is selected.
function galleryInitialRow(currentRow, count) {
    if (count <= 0)
        return -1;
    return currentRow >= 0 && currentRow < count ? currentRow : 0;
}

// Back/forward history. Returns {entries, index}. Navigating to the current entry changes nothing;
// navigating elsewhere drops the forward entries.
function pushHistory(entries, index, url) {
    const key = String(url);
    if (index >= 0 && index < entries.length && String(entries[index]) === key)
        return {entries: entries, index: index};
    const next = entries.slice(0, index + 1);
    next.push(url);
    return {entries: next, index: next.length - 1};
}

// Type-to-select buffer: keystrokes within `resetMs` extend the prefix, a pause starts over.
function typeahead(buffer, text, elapsedMs, resetMs) {
    return elapsedMs > resetMs ? text : buffer + text;
}

// Clicking a list header: the active column flips direction, another column takes its default.
function sortClick(currentKey, currentDescending, clickedKey, clickedDefaultDescending) {
    if (clickedKey === currentKey)
        return {key: currentKey, descending: !currentDescending};
    return {key: clickedKey, descending: clickedDefaultDescending};
}

// Indices of icon grid cells intersecting a rubber band rectangle (content coordinates).
function cellsInRect(x1, y1, x2, y2, cellWidth, cellHeight, columns, count) {
    const out = [];
    if (count <= 0 || columns <= 0 || cellWidth <= 0 || cellHeight <= 0)
        return out;
    const left = Math.min(x1, x2), right = Math.max(x1, x2);
    const top = Math.min(y1, y2), bottom = Math.max(y1, y2);
    const c0 = Math.max(0, Math.floor(left / cellWidth));
    const c1 = Math.min(columns - 1, Math.floor(right / cellWidth));
    const r0 = Math.max(0, Math.floor(top / cellHeight));
    const r1 = Math.floor(bottom / cellHeight);
    for (let r = r0; r <= r1; r++) {
        for (let c = c0; c <= c1; c++) {
            const i = r * columns + c;
            if (i < count)
                out.push(i);
        }
    }
    return out;
}

// Column view: index of the segment list where `target` (a folder url string) branches off `segments`
// (array of url strings), i.e. how many leading columns can be kept.
function commonPrefix(segments, target) {
    let n = 0;
    while (n < segments.length && n < target.length && String(segments[n]) === String(target[n]))
        n++;
    return n;
}

// A file name as shown in a label (GF-105, like Finder): line breaks become a return symbol, and the bidirectional
// override, embedding and isolate controls (U+202A-U+202E, U+2066-U+2069) are written out as "<U+202E>" so a name
// cannot reorder the text around it ("evil\u202Efdp.exe" does not read "evilexe.pdf"). The marks LRM and RLM stay.
function displayName(name) {
    return String(name).replace(/[\r\n]+/g, "\u23CE").replace(/[\u202A-\u202E\u2066-\u2069]/g,
        c => "<U+" + c.charCodeAt(0).toString(16).toUpperCase() + ">");
}
