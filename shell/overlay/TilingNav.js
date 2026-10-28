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
