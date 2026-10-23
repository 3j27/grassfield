.pragma library

// Overview layout (spec O2): pure functions, no QML types, unit-tested.
//
// layout(rects, area, opts): rects [{id, x, y, w, h}] are the real windows (monitor-relative),
// area {x, y, w, h} is the free region. Returns {scale, rects: [{id, x, y, w, h}]} in the same
// order. Every window is drawn at one uniform scale <= opts.maxScale. Relative positions are
// kept: centers are scaled about the group's center, then overlaps (closer than opts.gap) are
// relaxed apart. If relaxation cannot fit the area at a scale, the scale shrinks; the last
// resort is row packing in reading order (always fits for a small enough scale).

function bounds(list) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const r of list) {
        x0 = Math.min(x0, r.x);
        y0 = Math.min(y0, r.y);
        x1 = Math.max(x1, r.x + r.w);
        y1 = Math.max(y1, r.y + r.h);
    }
    return {x: x0, y: y0, w: x1 - x0, h: y1 - y0};
}

// True when two rectangles are closer than `gap` on both axes (including overlap).
function conflicts(a, b, gap) {
    const eps = 1e-6;
    return a.x < b.x + b.w + gap - eps && b.x < a.x + a.w + gap - eps && a.y < b.y + b.h + gap - eps && b.y < a.y + a.h + gap - eps;
}

function anyConflict(list, gap) {
    for (let i = 0; i < list.length; i++) {
        for (let j = i + 1; j < list.length; j++) {
            if (conflicts(list[i], list[j], gap))
                return true;
        }
    }
    return false;
}

function inside(list, area) {
    const eps = 1e-6;
    for (const r of list) {
        if (r.x < area.x - eps || r.y < area.y - eps || r.x + r.w > area.x + area.w + eps || r.y + r.h > area.y + area.h + eps)
            return false;
    }
    return true;
}

function clampInto(r, area) {
    r.x = Math.max(area.x, Math.min(r.x, area.x + area.w - r.w));
    r.y = Math.max(area.y, Math.min(r.y, area.y + area.h - r.h));
}

// Scaled copy of the windows: sizes by s, centers by s about the group's center, then the
// group is centered in the area.
function scaled(rects, area, s) {
    const b = bounds(rects);
    const cx = b.x + b.w / 2;
    const cy = b.y + b.h / 2;
    const acx = area.x + area.w / 2;
    const acy = area.y + area.h / 2;
    return rects.map(r => {
        const w = r.w * s;
        const h = r.h * s;
        return {id: r.id, x: acx + (r.x + r.w / 2 - cx) * s - w / 2, y: acy + (r.y + r.h / 2 - cy) * s - h / 2, w: w, h: h};
    });
}

// Push conflicting rectangles apart along the axis of least penetration, inside the area.
// Capped at maxPasses; stops early when a pass moves nothing. True when no conflict is left.
function relax(list, area, gap, maxPasses) {
    for (let iter = 0; iter < maxPasses; iter++) {
        let moved = false;
        for (let i = 0; i < list.length; i++) {
            for (let j = i + 1; j < list.length; j++) {
                const a = list[i];
                const b = list[j];
                const acx = a.x + a.w / 2;
                const acy = a.y + a.h / 2;
                const bcx = b.x + b.w / 2;
                const bcy = b.y + b.h / 2;
                // Penetration (positive) along each axis, including the gap; a conflict needs
                // both positive (inlined: this is the hot loop).
                const px = (a.w + b.w) / 2 + gap - Math.abs(acx - bcx);
                const py = (a.h + b.h) / 2 + gap - Math.abs(acy - bcy);
                if (px <= 1e-6 || py <= 1e-6)
                    continue;
                if (px <= py) {
                    const d = (px / 2 + 0.01) * (acx <= bcx ? -1 : 1);
                    a.x += d;
                    b.x -= d;
                } else {
                    const d = (py / 2 + 0.01) * (acy <= bcy ? -1 : 1);
                    a.y += d;
                    b.y -= d;
                }
                clampInto(a, area);
                clampInto(b, area);
                moved = true;
            }
        }
        if (!moved)
            return true;
    }
    return !anyConflict(list, gap);
}

// Windows in reading order (top to bottom, then left to right): indices into rects.
function readingOrder(rects) {
    return rects.map((r, i) => i).sort((p, q) => {
        const a = rects[p];
        const b = rects[q];
        const dy = (a.y + a.h / 2) - (b.y + b.h / 2);
        return dy !== 0 ? dy : (a.x + a.w / 2) - (b.x + b.w / 2);
    });
}

// Row packing in reading order with `rowCount` rows of equal count, computed directly: the
// largest scale (<= maxScale) at which every row fits the width and the rows fit the height
// (gaps are not scaled, so each bound is linear in the scale). Null when no positive scale fits.
function packRows(rects, order, area, gap, rowCount, maxScale) {
    const perRow = Math.ceil(rects.length / rowCount);
    const rows = [];
    for (let k = 0; k < order.length; k += perRow)
        rows.push(order.slice(k, k + perRow));
    let s = maxScale;
    let sumH = 0;
    for (const row of rows) {
        let sw = 0;
        let mh = 0;
        for (const i of row) {
            sw += rects[i].w;
            mh = Math.max(mh, rects[i].h);
        }
        s = Math.min(s, (area.w - gap * (row.length - 1)) / sw);
        sumH += mh;
    }
    s = Math.min(s, (area.h - gap * (rows.length - 1)) / sumH);
    if (!(s > 0))
        return null;
    s *= 0.9999;
    const heights = [];
    for (const row of rows) {
        let mh = 0;
        for (const i of row)
            mh = Math.max(mh, rects[i].h * s);
        heights.push(mh);
    }
    let total = gap * (rows.length - 1);
    for (const h of heights)
        total += h;
    const out = new Array(rects.length);
    let y = area.y + (area.h - total) / 2;
    rows.forEach((row, ri) => {
        let rw = gap * (row.length - 1);
        for (const i of row)
            rw += rects[i].w * s;
        let x = area.x + (area.w - rw) / 2;
        for (const i of row) {
            const w = rects[i].w * s;
            const h = rects[i].h * s;
            out[i] = {id: rects[i].id, x: x, y: y + (heights[ri] - h) / 2, w: w, h: h};
            x += w + gap;
        }
        y += heights[ri] + gap;
    });
    return {scale: s, rects: out};
}

// Relative positions kept, overlaps relaxed (capped), at scale s; null when it does not fit.
function tryRelaxed(valid, area, gap, s) {
    const list = scaled(valid, area, s);
    for (const r of list)
        clampInto(r, area);
    if (!inside(list, area))
        return null;
    if (anyConflict(list, gap) && !relax(list, area, gap, 12))
        return null;
    return inside(list, area) && !anyConflict(list, gap) ? {scale: s, rects: list} : null;
}

// Cheap signature of the layout inputs, to skip recomputation when nothing changed.
function signature(rects, area) {
    let out = Math.round(area.x) + "," + Math.round(area.y) + "," + Math.round(area.w) + "," + Math.round(area.h);
    for (const r of rects)
        out += "|" + r.id + ":" + Math.round(r.x) + "," + Math.round(r.y) + "," + Math.round(r.w) + "," + Math.round(r.h);
    return out;
}

function layout(rects, area, opts) {
    const maxScale = opts && opts.maxScale > 0 ? opts.maxScale : 0.8;
    const gap = opts && opts.gap >= 0 ? opts.gap : 24;
    if (!rects || rects.length === 0)
        return {scale: maxScale, rects: []};
    const valid = rects.map(r => ({id: r.id, x: r.x, y: r.y, w: Math.max(1, r.w), h: Math.max(1, r.h)}));
    const b = bounds(valid);
    const top = Math.min(maxScale, area.w / b.w, area.h / b.h);

    // 1. Row packing in reading order (cheap, direct): the fallback, and the yardstick for the
    // relaxed layout, which is kept whenever it is not clearly smaller (a stack of windows on
    // top of each other relaxes into one thin column).
    const order = readingOrder(valid);
    const rowLimit = Math.min(valid.length, Math.ceil(Math.sqrt(valid.length)) + 1);
    let packedResult = null;
    for (let rows = 1; rows <= valid.length; rows++) {
        if (rows > rowLimit && packedResult)
            break;
        const packed = packRows(valid, order, area, gap, rows, maxScale);
        if (packed && (!packedResult || packed.scale > packedResult.scale * 1.001))
            packedResult = packed;
    }
    // 2. Relative positions kept, overlaps relaxed: binary search (<= 5 steps) on the scale in
    // [floor, top], where floor is the smallest scale still preferred over the packed layout.
    let relaxed = tryRelaxed(valid, area, gap, top);
    if (!relaxed) {
        let lo = packedResult ? Math.min(top, packedResult.scale / 1.3) : top * 0.02;
        let hi = top;
        const first = tryRelaxed(valid, area, gap, lo);
        if (first) {
            relaxed = first;
            for (let step = 0; step < 5 && hi - lo > top * 0.04; step++) {
                const mid = (lo + hi) / 2;
                const res = tryRelaxed(valid, area, gap, mid);
                if (res) {
                    relaxed = res;
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
        }
    }
    if (relaxed && (!packedResult || packedResult.scale <= relaxed.scale * 1.3))
        return relaxed;
    if (packedResult)
        return packedResult;
    return {scale: 0.01, rects: scaled(valid, area, 0.01)};
}

// Free region of one output's chrome surface (surface coordinates, the surface starts below the menu bar): below the
// Spaces bar, above the Dock (when it takes space) and above the strip for the window label under the bottom row.
// size {w, h} is the output size; r {menubar, barBottom, margin, label, dock, dockLeft, dockRight}, dock = the Dock's
// height at the bottom and dockLeft / dockRight its width on a side edge (0 for an auto-hidden Dock or another edge).
// `strip` (optional) is the height of the minimized-windows strip at the bottom (stripHeight).
function freeArea(size, r) {
    const left = r.dockLeft || 0;
    return {
        x: r.margin + left,
        y: r.barBottom + r.margin,
        w: size.w - 2 * r.margin - left - (r.dockRight || 0),
        h: size.h - r.menubar - r.barBottom - 2 * r.margin - r.label - r.dock - (r.strip || 0)
    };
}

// ---- Minimized windows (macOS Mission Control: a row of smaller tiles below a divider) ----

// Height of the minimized strip at the bottom of the free area: tile, title and the room above and below. 0 without any.
// t = {w, h, label, gap, pad}.
function stripHeight(count, t) {
    return count > 0 ? t.h + t.label + 2 * t.pad : 0;
}

// Tiles of the strip: one row centred in `b` = {x, w, bottom} (bottom = the lowest y the strip may use), each tile t.w x
// t.h, narrower (the same aspect) when the row would not fit. Returns {height, dividerY, rects: [{x, y, w, h}]}: the
// divider is a hairline at dividerY, the tiles start t.pad below it and the title goes under each tile.
function stripRects(count, b, t) {
    if (!(count > 0))
        return {height: 0, dividerY: b.bottom, rects: []};
    const w = Math.max(1, Math.min(t.w, (b.w - (count - 1) * t.gap) / count));
    const h = w * t.h / t.w;
    const height = stripHeight(count, t);
    const top = b.bottom - height;
    const total = count * w + (count - 1) * t.gap;
    const x0 = b.x + (b.w - total) / 2;
    const rects = [];
    for (let i = 0; i < count; i++)
        rects.push({x: x0 + i * (w + t.gap), y: top + t.pad, w: w, h: h});
    return {height: height, dividerY: top, rects: rects};
}

function intersects(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

// Position {x, y, w, h} of a window's name label (w x h, `pad` from edges): under rects[index], centered, shifted
// sideways or, as the last resort, drawn inside the window at its bottom, so that it never covers another window's
// rectangle (the title band of the window in the next row belongs to that rectangle). `bounds` {w, h} is the surface.
function labelRect(rects, index, w, h, pad, bounds) {
    const r = rects[index];
    const maxX = bounds.w - w - pad;
    const clampX = x => Math.max(pad, Math.min(maxX, x));
    const y = Math.min(bounds.h - h - pad, r.y + r.h + pad);
    const candidates = [
        {x: clampX(r.x + (r.w - w) / 2), y: y},
        {x: clampX(r.x), y: y},
        {x: clampX(r.x + r.w - w), y: y},
        {x: clampX(r.x + (r.w - w) / 2), y: Math.max(r.y, r.y + r.h - h - pad)}
    ];
    for (const c of candidates) {
        const box = {x: c.x, y: c.y, w: w, h: h};
        let clear = true;
        for (let i = 0; i < rects.length; i++) {
            if (i !== index && intersects(box, rects[i])) {
                clear = false;
                break;
            }
        }
        if (clear)
            return box;
    }
    const last = candidates[3];
    return {x: last.x, y: last.y, w: w, h: h};
}

// Gap between windows that leaves room for the name label under a window (label height plus the padding above and
// below it), never below the spec minimum.
function labelAwareGap(minGap, labelHeight, pad) {
    return Math.max(minGap, labelHeight + 2 * pad);
}

// Spatial keyboard navigation: index of the rectangle nearest to rects[from] in direction
// dir ("left"|"right"|"up"|"down"), or -1. Candidates must lie on that side of the current
// center; off-axis distance is weighted double.
function neighbor(rects, from, dir) {
    if (from < 0 || from >= rects.length)
        return -1;
    const c = rects[from];
    const cx = c.x + c.w / 2;
    const cy = c.y + c.h / 2;
    let best = -1;
    let bestScore = Infinity;
    for (let i = 0; i < rects.length; i++) {
        if (i === from)
            continue;
        const dx = rects[i].x + rects[i].w / 2 - cx;
        const dy = rects[i].y + rects[i].h / 2 - cy;
        let along, across;
        if (dir === "left") {
            along = -dx;
            across = dy;
        } else if (dir === "right") {
            along = dx;
            across = dy;
        } else if (dir === "up") {
            along = -dy;
            across = dx;
        } else {
            along = dy;
            across = dx;
        }
        if (along <= 0.5)
            continue;
        const score = along + 2 * Math.abs(across);
        if (score < bestScore) {
            bestScore = score;
            best = i;
        }
    }
    return best;
}
