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
function relax(list, area, gap) {
    for (let iter = 0; iter < 300; iter++) {
        let moved = false;
        for (let i = 0; i < list.length; i++) {
            for (let j = i + 1; j < list.length; j++) {
                const a = list[i];
                const b = list[j];
                if (!conflicts(a, b, gap))
                    continue;
                const acx = a.x + a.w / 2;
                const acy = a.y + a.h / 2;
                const bcx = b.x + b.w / 2;
                const bcy = b.y + b.h / 2;
                // Penetration (positive) along each axis, including the gap.
                const px = (a.w + b.w) / 2 + gap - Math.abs(acx - bcx);
                const py = (a.h + b.h) / 2 + gap - Math.abs(acy - bcy);
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

// Row packing in reading order (top to bottom, then left to right) at scale s, or null when
// it does not fit.
function packRows(rects, area, s, gap) {
    const order = rects.map((r, i) => i).sort((p, q) => {
        const a = rects[p];
        const b = rects[q];
        const dy = (a.y + a.h / 2) - (b.y + b.h / 2);
        return dy !== 0 ? dy : (a.x + a.w / 2) - (b.x + b.w / 2);
    });
    const rows = [];
    let row = null;
    for (const i of order) {
        const w = rects[i].w * s;
        const h = rects[i].h * s;
        if (w > area.w + 1e-6)
            return null;
        if (!row || row.w + gap + w > area.w + 1e-6) {
            row = {items: [], w: -gap, h: 0};
            rows.push(row);
        }
        row.items.push({i: i, w: w, h: h});
        row.w += gap + w;
        row.h = Math.max(row.h, h);
    }
    let total = -gap;
    for (const r of rows)
        total += gap + r.h;
    if (total > area.h + 1e-6)
        return null;
    const out = new Array(rects.length);
    let y = area.y + (area.h - total) / 2;
    for (const r of rows) {
        let x = area.x + (area.w - r.w) / 2;
        for (const it of r.items) {
            out[it.i] = {id: rects[it.i].id, x: x, y: y + (r.h - it.h) / 2, w: it.w, h: it.h};
            x += it.w + gap;
        }
        y += r.h + gap;
    }
    return out;
}

function layout(rects, area, opts) {
    const maxScale = opts && opts.maxScale > 0 ? opts.maxScale : 0.8;
    const gap = opts && opts.gap >= 0 ? opts.gap : 24;
    if (!rects || rects.length === 0)
        return {scale: maxScale, rects: []};
    const valid = rects.map(r => ({id: r.id, x: r.x, y: r.y, w: Math.max(1, r.w), h: Math.max(1, r.h)}));
    const b = bounds(valid);
    let s = Math.min(maxScale, area.w / b.w, area.h / b.h);

    // 1. Relative positions kept, overlaps relaxed, scale reduced until it fits.
    let relaxed = null;
    for (let step = 0; step < 60; step++, s *= 0.94) {
        const list = scaled(valid, area, s);
        for (const r of list)
            clampInto(r, area);
        if (inside(list, area) && (!anyConflict(list, gap) || relax(list, area, gap)) && inside(list, area) && !anyConflict(list, gap)) {
            relaxed = {scale: s, rects: list};
            break;
        }
    }
    // 2. Row packing in reading order: also the fallback, and preferred when it gives clearly
    // larger windows (e.g. windows stacked on top of each other relax into one thin column).
    let packedResult = null;
    let ps = maxScale;
    for (let step = 0; step < 200; step++, ps *= 0.95) {
        const packed = packRows(valid, area, ps, gap);
        if (packed) {
            packedResult = {scale: ps, rects: packed};
            break;
        }
    }
    if (relaxed && (!packedResult || packedResult.scale <= relaxed.scale * 1.3))
        return relaxed;
    if (packedResult)
        return packedResult;
    s = ps;
    return {scale: s, rects: scaled(valid, area, s)};
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

// A Hyprland window address is hex, with or without the 0x prefix. Returns it without the
// prefix, or "" when it is not valid hex (untrusted data is never interpolated into Lua).
function hexAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}
