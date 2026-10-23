.pragma library

// Pure placement rules for menus (macOS model: a menu never moves once it is open; a submenu opens beside its row, to the
// right, or to the left when there is no room, and the parent stays put).

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(v, hi));
}

// Top-left of a context menu of `size` {w, h} opened at the point `at` {x, y} inside an area {w, h}, `margin` from the edges.
// Right of the pointer, below it; with no room on the right it opens to the left of the pointer, with no room below it slides
// up. It depends on the menu alone, never on a submenu: opening one must not move it.
function place(at, size, area, margin) {
    let x = at.x;
    if (x + size.w > area.w - margin)
        x = at.x - size.w;
    x = clamp(x, margin, Math.max(margin, area.w - margin - size.w));
    const y = clamp(at.y, margin, Math.max(margin, area.h - margin - size.h));
    return {x: x, y: y};
}

// X of a submenu of width `subW` relative to its parent menu (left edge at `parentX` in the area, width `parentW`): to the
// right, overlapping the parent by `overlap`; to the left when it would cross the right edge of an area of width `areaW`
// (`margin` kept); with no room on either side, as far right as the area allows.
function submenuX(parentX, parentW, subW, overlap, areaW, margin) {
    const right = parentW - overlap;
    if (parentX + right + subW <= areaW - margin)
        return right;
    const left = overlap - subW;
    return parentX + left >= margin ? left : Math.max(margin - parentX, areaW - margin - parentX - subW);
}

// Y of a submenu of height `subH` relative to its parent: the top of its row (`rowY`), moved up to stay inside the area.
function submenuY(parentY, rowY, subH, areaH, margin) {
    return Math.max(margin - parentY, Math.min(rowY, areaH - margin - parentY - subH));
}
