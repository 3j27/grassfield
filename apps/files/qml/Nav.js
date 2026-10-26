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

// The view a tab shows when it opens a folder (docs/specs/files.md F-3): column view sticks while browsing; otherwise the
// folder's own view when one was chosen for it (`stored`), else the view the tab already shows (`current`; "" for a new
// tab), else the default view (`fallback`).
function viewFor(current, stored, fallback) {
    const c = viewModes.indexOf(String(current)) >= 0 ? String(current) : "";
    if (c === "columns")
        return c;
    if (viewModes.indexOf(String(stored)) >= 0)
        return String(stored);
    return c !== "" ? c : normalizeViewMode(fallback);
}

// The arrangement of a folder: its own sort key and order when they were chosen for it (`stored`: {sortKey,
// sortDescending}, each optional), else the defaults; a stored key without an order takes that key's default order.
function sortFor(stored, defaultKey, defaultDescending, defaultDescendingOf) {
    if (stored && stored.sortKey !== undefined) {
        const key = Number(stored.sortKey);
        return {key: key, descending: stored.sortDescending !== undefined ? stored.sortDescending === true : defaultDescendingOf(key)};
    }
    return {key: defaultKey, descending: stored && stored.sortDescending !== undefined ? stored.sortDescending === true : defaultDescending};
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

// Keyboard move in the grouped icon view. `groups`: [{first, count, columns}] in row order, `columns` the items per line
// of the group (its count when the group is one row). Left/Right walk the rows across groups; Up/Down move a line, from a
// group's first or last line to the next group's nearest line at the same place; PageUp/PageDown move a group.
function groupedIconMove(current, key, groups) {
    if (groups.length === 0)
        return -1;
    const last = groups[groups.length - 1];
    const count = last.first + last.count;
    if (current < 0 || current >= count)
        return key === "end" ? count - 1 : 0;
    let g = 0;
    while (g < groups.length - 1 && current >= groups[g].first + groups[g].count)
        g++;
    const group = groups[g];
    const cols = Math.max(1, group.columns);
    const i = current - group.first;
    const col = i % cols;
    // Row `line` of group `h` at column `c`, clamped to that line's last item.
    function at(h, line, c) {
        const target = groups[h];
        const tc = Math.max(1, target.columns);
        return target.first + Math.min(target.count - 1, line * tc + Math.min(c, tc - 1));
    }
    switch (key) {
    case "left":
        return Math.max(0, current - 1);
    case "right":
        return Math.min(count - 1, current + 1);
    case "up":
        if (i - cols >= 0)
            return current - cols;
        return g > 0 ? at(g - 1, Math.floor((groups[g - 1].count - 1) / Math.max(1, groups[g - 1].columns)), col) : current;
    case "down":
        if (i + cols < group.count)
            return current + cols;
        if (Math.floor(i / cols) < Math.floor((group.count - 1) / cols))
            return group.first + group.count - 1;
        return g < groups.length - 1 ? at(g + 1, 0, col) : current;
    case "home":
        return 0;
    case "end":
        return count - 1;
    case "pageup":
        return g > 0 ? at(g - 1, 0, col) : group.first;
    case "pagedown":
        return g < groups.length - 1 ? at(g + 1, 0, col) : group.first + group.count - 1;
    }
    return current;
}

// The grouped icon view's layout: each group of `groups` ([{first, count, columns}], as groupedIconMove takes them) is a
// header `headerHeight` high over its lines of cells `cellHeight` high. Returns the top of each group, then the whole height.
function groupedIconTops(groups, headerHeight, cellHeight) {
    const tops = [];
    let y = 0;
    for (let g = 0; g < groups.length; g++) {
        tops.push(y);
        y += headerHeight + Math.ceil(groups[g].count / Math.max(1, groups[g].columns)) * cellHeight;
    }
    tops.push(y);
    return tops;
}

// Where `row` sits in the grouped icon view: {group, index (in the group), line, column, x (in the group's own, unscrolled
// lines), y (the top of its cell in the content)}; null for a row in no group.
function groupedIconCell(row, cellWidth, cellHeight, headerHeight, groups) {
    let y = 0;
    for (let g = 0; g < groups.length; g++) {
        const cols = Math.max(1, groups[g].columns);
        if (row >= groups[g].first && row < groups[g].first + groups[g].count) {
            const i = row - groups[g].first;
            const line = Math.floor(i / cols);
            return {group: g, index: i, line: line, column: i % cols, x: (i % cols) * cellWidth, y: y + headerHeight + line * cellHeight};
        }
        y += headerHeight + Math.ceil(groups[g].count / cols) * cellHeight;
    }
    return null;
}

// Rows of the grouped icon view under a rubber band (content coordinates). `groups`: [{first, count, columns, scrollX}],
// scrollX how far a one-line group is scrolled sideways.
function groupedIconCells(x1, y1, x2, y2, cellWidth, cellHeight, headerHeight, groups) {
    const out = [];
    const top = Math.min(y1, y2), bottom = Math.max(y1, y2);
    let y = 0;
    for (let g = 0; g < groups.length && y <= bottom; g++) {
        const cols = Math.max(1, groups[g].columns);
        const rowsTop = y + headerHeight;
        y = rowsTop + Math.ceil(groups[g].count / cols) * cellHeight;
        if (bottom < rowsTop || top >= y)
            continue;
        const dx = groups[g].scrollX || 0;
        const cells = cellsInRect(x1 + dx, top - rowsTop, x2 + dx, bottom - rowsTop, cellWidth, cellHeight, cols, groups[g].count);
        for (let i = 0; i < cells.length; i++)
            out.push(groups[g].first + cells[i]);
    }
    return out;
}

// Rows of a grouped list (FolderModel.groups: [{first, count}] in row order, each group under a header `headerHeight` high)
// that the vertical span [y1, y2] of the list's content covers.
function groupedRowsInSpan(y1, y2, rowHeight, headerHeight, groups) {
    const out = [];
    const top = Math.min(y1, y2), bottom = Math.max(y1, y2);
    let y = 0;
    for (let g = 0; g < groups.length; g++) {
        y += headerHeight;
        const first = groups[g].first, count = groups[g].count;
        const r0 = Math.max(0, Math.floor((top - y) / rowHeight));
        const r1 = Math.min(count - 1, Math.floor((bottom - y) / rowHeight));
        for (let r = r0; r <= r1; r++)
            out.push(first + r);
        y += count * rowHeight;
        if (y > bottom)
            break;
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
