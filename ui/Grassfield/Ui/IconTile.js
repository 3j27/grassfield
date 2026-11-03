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


// The tile edge (0: not a tile) of an image read with Canvas `createImageData(url)`: the image's own pixels ({width, height, data} RGBA, whatever the
// output's scale, the window's ratio or the source: an image://icon pixmap, an SVG or a PNG file), never drawn on the canvas. Only the alpha
// bytes are read, at a fixed stride (nearest, at the pixel centres): half of `n` (the shape test works on proportions, not pixels) squared
// reads whatever the image's size, then `measure`. 0 for an image that is not square (a tile is) or empty. About 1.5 ms (tst_icontile logs it).
function sideOfImageData(img, n, t) {
    const w = img.width, h = img.height;
    if (!(w > 0) || !(h > 0) || Math.abs(w - h) > t.iconModeOwnTileSquare * Math.max(w, h))
        return 0;
    const m = Math.max(32, n >> 1);
    const src = img.data;
    const mask = new Uint8Array(m * m * 4);
    const col = new Int32Array(m);
    for (let x = 0; x < m; x++)
        col[x] = (Math.min(w - 1, Math.floor((x + 0.5) * w / m)) << 2) + 3;
    for (let y = 0; y < m; y++) {
        const row = Math.min(h - 1, Math.floor((y + 0.5) * h / m)) * w * 4;
        const out = (y * m << 2) + 3;
        for (let x = 0; x < m; x++)
            mask[out + (x << 2)] = src[row + col[x]];
    }
    return measure(mask, m, t).side;
}

// The scale of the artwork of an icon whose tile has the edge `side` (over the box): its tile coincides with the system plate, whose side is
// 1 - 2 * inset. Clamped to the token range. A glyph or any other icon (side 0, null or undefined) keeps the glyph scale.
function artScale(side, t) {
    if (!(side > 0))
        return t.iconModeSysGlyphScale;
    const plate = 1 - 2 * t.iconModeSysPlateInset;
    return Math.max(t.iconModeOwnTileScaleMin, Math.min(t.iconModeOwnTileScaleMax, plate / side));
}
