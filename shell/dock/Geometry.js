.pragma library
.import "DockModel.js" as DockModel

// Dock geometry (pure, unit-tested): the tile size (Settings > Desktop & Dock > Size) and what follows from it.
// `base` is the dock token set {iconSize, padding, indicatorSize, spacing, bottomMargin, separatorHeight, badgeSize,
// radiusIcon}; sizes are px. The tokens describe the default size (base.iconSize); everything that is proportional to
// the tile scales with it, the rest (padding, spacing, indicator, margin) stays.

// A stored size read as a tile size: a whole number of px inside [min, max], `fallback` for anything else.
function clampSize(value, min, max, fallback) {
    const n = Number(value);
    if (typeof value === "boolean" || value === null || value === "" || !isFinite(n))
        return fallback;
    return Math.round(Math.max(min, Math.min(max, n)));
}

// The metrics of a Dock whose tiles are `size` px (the shape DockModel.shelfHeight / reservedHeight take, plus the
// proportional parts). The icon corner radius and the separator follow the tile; the badge grows with it but never
// gets smaller than its token (it holds text).
function metrics(size, base) {
    const k = size / base.iconSize;
    return {
        iconSize: size,
        padding: base.padding,
        indicatorSize: base.indicatorSize,
        spacing: base.spacing,
        bottomMargin: base.bottomMargin,
        separatorHeight: Math.round(base.separatorHeight * k),
        iconRadius: base.radiusIcon * k,
        badgeScale: Math.max(1, k),
        badgeSize: Math.round(base.badgeSize * Math.max(1, k))
    };
}

// ---- Position on screen (Settings > Position on screen: Left / Bottom / Right) ----
//
// The Dock lives in a transparent layer window anchored to its screen edge. Everything is written along two axes:
//   main  = along the Dock (x for a Dock at the bottom, y for one on the left or right edge), first tile at 0
//   cross = away from the screen edge (0 at the edge, the shelf is `margin` px off it, icons grow to larger values)
// and `rect()` turns main/cross boxes into window coordinates, so the shelf, the hit area, a tile target and a tooltip
// are one formula for the three edges. Magnify.js (scales, slots) and AutoHide.js (state machine) work on a coordinate
// along the main axis and a visible fraction: they are the same for every edge, only the pointer coordinate they get is
// `mainOf(edge, x, y)`.

var EDGES = ["left", "bottom", "right"];

// A stored value read as an edge: anything that is not left/right is the default, bottom.
function normalizeEdge(value) {
    return value === "left" || value === "right" ? value : "bottom";
}

function isVertical(edge) {
    return edge === "left" || edge === "right";
}

// Unit vector away from the screen edge: where icons grow, bounce and where labels and menus go.
function outward(edge) {
    if (edge === "left")
        return {x: 1, y: 0};
    if (edge === "right")
        return {x: -1, y: 0};
    return {x: 0, y: -1};
}

// Extent of a window (w x h) along the main axis and across it.
function mainSize(edge, w, h) {
    return isVertical(edge) ? h : w;
}

function crossSize(edge, w, h) {
    return isVertical(edge) ? w : h;
}

// Coordinate along the main axis of a point (x, y) of the window.
function mainOf(edge, x, y) {
    return isVertical(edge) ? y : x;
}

// Distance from the screen edge of a point (x, y) of a w x h window.
function crossOf(edge, x, y, w, h) {
    if (edge === "left")
        return x;
    if (edge === "right")
        return w - x;
    return h - y;
}

// Box [main0, main0 + mainLen] x [cross0, cross0 + crossLen] (cross0: distance of its side nearest to the screen edge,
// may be negative: a shelf slid out of sight) as a rectangle {x, y, w, h} of a w x h window anchored on `edge`.
function rect(edge, w, h, main0, mainLen, cross0, crossLen) {
    if (edge === "left")
        return {x: cross0, y: main0, w: crossLen, h: mainLen};
    if (edge === "right")
        return {x: w - cross0 - crossLen, y: main0, w: crossLen, h: mainLen};
    return {x: main0, y: h - cross0 - crossLen, w: mainLen, h: crossLen};
}

// Top-left corner of the window in screen coordinates. A vertical window is anchored top and bottom and the compositor
// may leave a bar above it, so it is placed from the bottom of the screen (nothing reserves room there).
function windowOrigin(edge, screenW, screenH, w, h) {
    return {x: edge === "right" ? screenW - w : 0, y: screenH - h};
}

// Room the window keeps beside the shelf for a label or a dragged icon (px): the label above a Dock at the bottom needs
// its own height, the label beside a Dock on a side edge its width.
function room(edge, tooltipArea, tooltipSideArea, dragArea) {
    return Math.max(isVertical(edge) ? tooltipSideArea : tooltipArea, dragArea);
}

// Window extent across the Dock: shelf, margin, the growth of magnified icons and the room beside it.
function depth(thickness, margin, overhang, roomPx) {
    return thickness + margin + overhang + roomPx;
}

// Shelf box in the window: centred along the main axis, `margin` off the edge, slid toward the edge by `slide` px
// (autohide).
function shelfRect(edge, w, h, length, thickness, margin, slide) {
    return rect(edge, w, h, (mainSize(edge, w, h) - length) / 2, length, margin - slide, thickness);
}

// The input area of the window (mask): the whole strip of `zone` px along the edge while the Dock is away, otherwise the
// shelf's length and, across, the shelf (plus the room for magnified icons and labels while the pointer is on it, or
// the whole window while a tile is dragged). `s` = {revealed, dragging, pointerActive, shelfMain0, shelfLength, thickness,
// margin, overhang, room, zone}.
function hitRect(edge, w, h, s) {
    if (!s.revealed)
        return rect(edge, w, h, 0, mainSize(edge, w, h), 0, s.zone);
    const cross = s.dragging ? crossSize(edge, w, h) : s.pointerActive ? s.thickness + s.margin + s.overhang + s.room : s.thickness + s.margin;
    return rect(edge, w, h, s.shelfMain0, s.shelfLength, 0, cross);
}

// Where the icon of a tile sits in the tile's own box. The tile is iconSize + indicatorArea across (the running dot on
// the screen-edge side, then the icon) and iconPx along; a magnified icon (iconPx > iconSize) grows away from the edge.
function iconOrigin(edge, iconSize, iconPx, indicatorArea) {
    if (edge === "left")
        return {x: indicatorArea, y: 0};
    if (edge === "right")
        return {x: iconSize - iconPx, y: 0};
    return {x: 0, y: iconSize - iconPx};
}

// The running dot in the tile's box. `lift` is how far the tile has moved away from the edge (hover rise): the dot stays on
// the shelf.
function dotOrigin(edge, tileW, tileH, iconSize, spacing, dotSize, lift) {
    if (edge === "left")
        return {x: -lift, y: (tileH - dotSize) / 2};
    if (edge === "right")
        return {x: iconSize + spacing + lift, y: (tileH - dotSize) / 2};
    return {x: (tileW - dotSize) / 2, y: iconSize + spacing + lift};
}

// The label of a tile, in the tile's box: above the icon (bottom), beside it on the side away from the screen edge.
// `ttW` x `ttH` is the label (its tail included), `gap` the room between it and the icon.
function tooltipOrigin(edge, tileW, tileH, iconSize, iconPx, indicatorArea, gap, ttW, ttH) {
    if (edge === "left")
        return {x: indicatorArea + iconPx + gap, y: (tileH - ttH) / 2};
    if (edge === "right")
        return {x: iconSize - iconPx - gap - ttW, y: (tileH - ttH) / 2};
    return {x: (tileW - ttW) / 2, y: tileH - indicatorArea - iconPx - gap - ttH};
}

// Which side of the label the tail is on: the one toward the tile.
function tooltipTailSide(edge) {
    return edge === "left" ? "left" : edge === "right" ? "right" : "bottom";
}

// Rectangle (window coordinates) of the unmagnified icon of the tile centred at `mainCenter` on the main axis: the target
// of the minimize animation. `margin`/`padding` as in the metrics, `indicatorArea` = indicator + spacing.
function tileRect(edge, w, h, mainCenter, iconSize, margin, padding, indicatorArea) {
    return rect(edge, w, h, mainCenter - iconSize / 2, iconSize, margin + padding + indicatorArea, iconSize);
}

// Where the Dock menu of a tile opens (screen coordinates; `center` is the tile centre along the main axis in screen
// coordinates): above a Dock at the bottom (centred on the tile, its bottom edge at y), beside a Dock on a side edge
// (centred on the tile, its near edge at x), `gap` + `tailHeight` away from the shelf for the menu's tail.
// The alignment names are Popups.align values.
function menuAnchor(edge, screenW, screenH, center, thickness, margin, gap, tailHeight) {
    const off = margin + thickness + gap + tailHeight;
    if (edge === "left")
        return {x: off, y: center, align: "rightOf"};
    if (edge === "right")
        return {x: screenW - off, y: center, align: "leftOf"};
    return {x: center, y: screenH - off, align: "above"};
}

// Components of a drag offset (screen dx, dy): along the Dock, and away from the screen edge (positive = out).
function dragMain(edge, dx, dy) {
    return isVertical(edge) ? dy : dx;
}

function dragOutward(edge, dx, dy) {
    const o = outward(edge);
    return o.x * dx + o.y * dy;
}

// The drag offset (screen dx, dy) with `main` along the Dock and `cross` away from the screen edge.
function dragVector(edge, main, cross) {
    const o = outward(edge);
    return isVertical(edge) ? {x: o.x * cross, y: main} : {x: main, y: o.y * cross};
}

// Insets {left, right, bottom} the Dock takes from a screen (its exclusive zone, 0 while auto-hidden): what the desktop
// icon grid, the widgets, Overview and the Apps panel keep clear.
function footprint(edge, m, autohide) {
    const zone = DockModel.reservedHeight(m, autohide);
    return {left: edge === "left" ? zone : 0, right: edge === "right" ? zone : 0, bottom: edge === "bottom" ? zone : 0};
}
