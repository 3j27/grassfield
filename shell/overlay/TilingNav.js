.pragma library

// Keyboard navigation of the tiling popover (docs/specs/tiling.md TL26, parity row M24: navigable with the arrows, Return and
// Esc once open; pure, unit-tested in tst_tilingnav). The popover is lines in reading order: each glyph section is one line
// of glyphs, each row below is a line of its own. entries: [{line, column, enabled}] in that order; a glyph's column is its
// place in its section, a row's is 0.

function selectable(entry) {
    return entry !== undefined && entry !== null && entry.enabled !== false;
}

function firstIn(entries, dir) {
    const n = entries.length;
    for (let k = 0; k < n; k++) {
        const i = dir > 0 ? k : n - 1 - k;
        if (selectable(entries[i]))
            return i;
    }
    return -1;
}

// The entry `key` moves to from `index` (-1: nothing chosen yet): "left"/"right" within a line of glyphs (wrapping),
// "up"/"down" to the previous or next line that has a selectable entry (wrapping), keeping the nearest column, "home"/"end"
// the first or last selectable entry. -1 when nothing is selectable; `index` for a key that does not move.
function step(entries, index, key) {
    if (!Array.isArray(entries) || entries.length === 0)
        return -1;
    if (key === "home" || (index < 0 && (key === "down" || key === "right" || key === "left")))
        return firstIn(entries, 1);
    if (key === "end" || (index < 0 && key === "up"))
        return firstIn(entries, -1);
    const here = entries[index];
    if (!here)
        return -1;
    if (key === "left" || key === "right") {
        const line = entries.map((e, i) => ({e: e, i: i})).filter(o => o.e.line === here.line);
        const at = line.findIndex(o => o.i === index);
        const dir = key === "right" ? 1 : -1;
        for (let k = 1; k < line.length; k++) {
            const o = line[(at + dir * k + line.length * k) % line.length];
            if (selectable(o.e))
                return o.i;
        }
        return index;
    }
    if (key !== "up" && key !== "down")
        return index;
    const lines = [];
    for (const e of entries) {
        if (lines.indexOf(e.line) < 0)
            lines.push(e.line);
    }
    const from = lines.indexOf(here.line);
    const dir = key === "down" ? 1 : -1;
    for (let k = 1; k <= lines.length; k++) {
        const line = lines[(from + dir * k + lines.length * k) % lines.length];
        let best = -1;
        for (let i = 0; i < entries.length; i++) {
            if (entries[i].line !== line || !selectable(entries[i]))
                continue;
            if (best < 0 || Math.abs(entries[i].column - here.column) < Math.abs(entries[best].column - here.column))
                best = i;
        }
        if (best >= 0)
            return best;
    }
    return index;
}

// The number keys of the Layouts section (TL26, TL27): a first digit picks a layout (1 the first of the section), a second
// a zone of it (1 its first zone). layouts: [{zones: [...], enabled}] in section order; picked: the index of the layout
// picked so far, -1 for none; digit: 1 to 9. {picked, zone}: zone -1 until a zone is chosen (the caller then places the
// window there); a digit with no layout or zone of that number, or a greyed layout, changes nothing.
function numberPick(layouts, picked, digit) {
    const none = {picked: picked, zone: -1};
    if (!Array.isArray(layouts) || !Number.isInteger(digit) || digit < 1 || digit > 9)
        return none;
    if (picked < 0 || picked >= layouts.length) {
        const layout = layouts[digit - 1];
        return layout && layout.enabled !== false ? {picked: digit - 1, zone: -1} : {picked: -1, zone: -1};
    }
    const zones = layouts[picked].zones;
    return Array.isArray(zones) && digit <= zones.length ? {picked: picked, zone: digit - 1} : none;
}

// The digit 1 to 9 of a key press for numberPick, 0 for any other key: the digit keys by their character (Qt.Key_1 to
// Qt.Key_9, the keypad's too), or the top row by position (xkb keycodes 10 to 18, evdev KEY_1 to KEY_9 plus 8), so that the
// number keys work on AZERTY, where that row types symbols without Shift.
function digitOf(key, nativeScanCode) {
    if (key >= 0x31 && key <= 0x39)
        return key - 0x30;
    if (nativeScanCode >= 10 && nativeScanCode <= 18)
        return nativeScanCode - 9;
    return 0;
}
