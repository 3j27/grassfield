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
