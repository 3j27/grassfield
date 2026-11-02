.pragma library

// Whether an icon is already a rounded square that fills its box like the system plate (docs/specs/ui.md, "Icon shader",
// own-tile rule). Pure functions on an alpha mask, no I/O: the CPU shape test of IconShape.qml, decided once per icon file.
// The test looks at the alpha channel only (no colour analysis): a shadow (low alpha) never counts, a glyph or a folder
// fails the square, the fill or the corner test.
//
// `rgba` is the flat RGBA array of an n x n picture (Canvas getImageData), `t` the iconMode.ownTile* tokens (Tokens).

// The measured shape of the picture: {tile, side, reason}. `side` is the tile's edge over the box edge (0 when it is not a tile).
function measure(rgba, n, t) {
    const none = reason => ({tile: false, side: 0, reason: reason});
    const cut = t.iconModeOwnTileAlpha * 255;
    // The box of the shape: the extent of the opaque pixels along the middle rows and the middle columns (not of the whole picture, so
    // that a badge sticking out of a tile at a corner does not move the tile's edges).
    let x0 = n, y0 = n, x1 = -1, y1 = -1;
    const mid = Math.floor(n / 2);
    for (let k = mid - 1; k <= mid; k++) {
        for (let i = 0; i < n; i++) {
            if (rgba[(k * n + i) * 4 + 3] >= cut) {
                x0 = Math.min(x0, i);
                x1 = Math.max(x1, i);
            }
            if (rgba[(i * n + k) * 4 + 3] >= cut) {
                y0 = Math.min(y0, i);
                y1 = Math.max(y1, i);
            }
        }
    }
    if (x1 < 0 || y1 < 0)
        return none("empty");
    const w = x1 - x0 + 1;
    const h = y1 - y0 + 1;
    const big = Math.max(w, h);
    if (Math.abs(w - h) > t.iconModeOwnTileSquare * big)
        return none("not square");
    const side = (w + h) / (2 * n);
    if (side < t.iconModeOwnTileMinSide)
        return none("too small");
    if (Math.abs((x0 + x1 + 1) / 2 / n - 0.5) > t.iconModeOwnTileCentre || Math.abs((y0 + y1 + 1) / 2 / n - 0.5) > t.iconModeOwnTileCentre)
        return none("off centre");
    let opaque = 0;
    for (let y = y0; y <= y1; y++) {
        for (let x = x0; x <= x1; x++) {
            if (rgba[(y * n + x) * 4 + 3] >= cut)
                opaque++;
        }
    }
    const fill = opaque / (w * h);
    if (fill < t.iconModeOwnTileFillMin || fill > t.iconModeOwnTileFillMax)
        return {tile: false, side: 0, reason: "fill " + fill.toFixed(3)};
    // The four corners of the box of the tile are empty and the middle of its four edges are filled, a little inside the box.
    const d = Math.max(1, Math.round(t.iconModeOwnTileProbe * big));
    const solid = (x, y) => rgba[(y * n + x) * 4 + 3] >= cut;
    // A badge over one corner (a tile with a small emblem) is allowed to fill it: at least iconMode.ownTileCornersEmpty corners are empty.
    const empty = (solid(x0 + d, y0 + d) ? 0 : 1) + (solid(x1 - d, y0 + d) ? 0 : 1) + (solid(x0 + d, y1 - d) ? 0 : 1) + (solid(x1 - d, y1 - d) ? 0 : 1);
    if (empty < t.iconModeOwnTileCornersEmpty)
        return {tile: false, side: 0, reason: "corner filled"};
    // The middle half of each of the four edges is filled (a folder's tab, a glyph's arms are not): a tile has straight edges.
    const lo = Math.floor(0.25 * big);
    const hi = Math.ceil(0.75 * big);
    let run = [0, 0, 0, 0];
    for (let i = lo; i < hi; i++) {
        run[0] += solid(x0 + i, y0 + d) ? 1 : 0;
        run[1] += solid(x0 + i, y1 - d) ? 1 : 0;
        run[2] += solid(x0 + d, y0 + i) ? 1 : 0;
        run[3] += solid(x1 - d, y0 + i) ? 1 : 0;
    }
    for (const r of run) {
        if (r < t.iconModeOwnTileEdge * (hi - lo))
            return {tile: false, side: 0, reason: "edge empty"};
    }
    return {tile: true, side: side, reason: "tile", fill: fill};
}


// The tile edge (0: not a tile) of the picture just drawn into the n x n box of a Canvas (Canvas.Image target) by drawImage(source, 0, 0, n, n).
// A Canvas keeps its picture at a pixel ratio of its own (1 on a plain output, 2 on a HiDPI one) and what drawImage covers of it depends on
// the source: a file URL is drawn over the whole picture, an image://icon pixmap over its first n x n pixels. Reading the first n x n pixels
// only is right for the second and a quarter of the icon for the first (every icon "off centre": not a tile, a pale plate around a coloured
// tile on every Dock icon). So the picture is read once, in a window of 4n pixels, and measured as the first n x n pixels and, when that is not
// a tile, as the whole box at the ratio the canvas has (an opaque square painted UNDER the picture, "destination-over", tells how many pixels
// the n x n box covers). A tile passes the strict shape test only in the right window; anything else stays 0.
function sideOfCanvas(ctx, n, t) {
    const span = 4 * n;
    const big = ctx.getImageData(0, 0, span, span).data;
    const window = m => {
        const out = new Array(m * m * 4);
        for (let y = 0; y < m; y++) {
            for (let x = 0; x < m; x++) {
                const s = (y * span + x) * 4, d = (y * m + x) * 4;
                out[d] = big[s];
                out[d + 1] = big[s + 1];
                out[d + 2] = big[s + 2];
                out[d + 3] = big[s + 3];
            }
        }
        return out;
    };
    const first = measure(window(n), n, t);
    if (first.tile)
        return first.side;
    ctx.globalCompositeOperation = "destination-over";
    ctx.fillStyle = "#000000";
    ctx.fillRect(0, 0, n, n);
    const row = ctx.getImageData(0, 0, span, 1).data;
    ctx.globalCompositeOperation = "source-over";
    let cover = 0;
    for (let i = 0; i < span; i++) {
        if (row[i * 4 + 3] > 127)
            cover = i + 1;
    }
    const m = Math.min(span, cover);
    if (m <= n + 1)
        return 0;
    return measure(window(m), m, t).side;
}

// The scale of the artwork of an icon whose tile has the edge `side` (over the box): its tile coincides with the system plate, whose side is
// 1 - 2 * inset. Clamped to the token range. A glyph or any other icon (side 0, null or undefined) keeps the glyph scale.
function artScale(side, t) {
    if (!(side > 0))
        return t.iconModeSysGlyphScale;
    const plate = 1 - 2 * t.iconModeSysPlateInset;
    return Math.max(t.iconModeOwnTileScaleMin, Math.min(t.iconModeOwnTileScaleMax, plate / side));
}
