.pragma library

// Pure logic of the Stages strip (docs/specs/stages.md "Shell side"): tile geometry in layout coordinates, when the strip is
// shown, what a click or a drop asks of the plugin. No QML types; unit-tested in tests/unit/tst_stages.qml.
// `t` below is the metrics object {tileWidth, tileHeight, tileGap, edgeMargin, maxTiles, revealZone}, filled from Tokens.

// How many tiles fit in `availableHeight` (at least 1, at most t.maxTiles).
function capacity(availableHeight, t) {
    const n = Math.floor((availableHeight + t.tileGap) / (t.tileHeight + t.tileGap));
    return Math.max(1, Math.min(t.maxTiles, n));
}

// Number of tiles to ask for: one per strip stage, capped by what fits.
function tileCount(stripCount, availableHeight, t) {
    return Math.max(1, Math.min(stripCount, capacity(availableHeight, t)));
}

// Geometry of the strip on a screen {x, y, width, height} (logical, layout coordinates) with insets {left, top, bottom}
// (the Dock when it is on the left, the menu bar). Tiles are centred vertically in the free height, as macOS centres them.
// Returns {surface: {x, y, w, h}, tiles: [{x, y, w, h}], box: {x, y, w, h}, edge: {x, y, w, h}}; `box` (tiles with half a gap
// around them) and `edge` (the reveal zone) are relative to the surface, where the input region goes.
function geometry(screen, insets, count, t) {
    const top = insets.top + t.edgeMargin;
    const availH = Math.max(0, screen.height - top - Math.max(insets.bottom, t.edgeMargin));
    const n = Math.max(1, Math.min(count, t.maxTiles));
    const total = n * t.tileHeight + (n - 1) * t.tileGap;
    const first = top + Math.max(0, (availH - total) / 2);
    const sx = screen.x + insets.left;
    const surface = {x: sx, y: screen.y + top, w: t.tileWidth + 2 * t.edgeMargin, h: availH};
    const tiles = [];
    for (let i = 0; i < n; i++)
        tiles.push({x: sx + t.edgeMargin, y: screen.y + first + i * (t.tileHeight + t.tileGap), w: t.tileWidth, h: t.tileHeight});
    const half = t.tileGap / 2;
    const boxY = Math.max(surface.y, tiles[0].y - half);
    const boxEnd = Math.min(surface.y + surface.h, tiles[n - 1].y + t.tileHeight + half);
    return {
        surface: surface,
        tiles: tiles,
        box: {x: t.edgeMargin / 2, y: boxY - surface.y, w: t.tileWidth + t.edgeMargin, h: boxEnd - boxY},
        edge: {x: 0, y: 0, w: t.revealZone, h: surface.h}
    };
}

// Whether the strip is drawn: Stages is on, there is a stage to show, and no window overlaps it (unless the pointer revealed it).
function shown(on, stripCount, overlap, revealed) {
    return on && stripCount > 0 && (!overlap || revealed);
}

// The input region is the tiles' box while the strip is shown, else the thin edge zone (reveal on hover): never empty while
// Stages is on, so the plugin's strip check (the surface owns an input region) always has one to look at.
function edgeActive(on, isShown) {
    return on && !isShown;
}

// Request for the plugin: Stages on or updated for the screens in `strips` ([{monitor, hidden, tiles}]).
function onRequest(strips, durationMs, curve) {
    return {op: "on", durationMs: durationMs, curve: curve, strips: strips};
}

// Click on tile `slot` of a monitor state (StagesState.parse monitors entry): activate; Shift merges into the active stage.
function clickRequest(monitor, slot, shift) {
    const s = monitor ? monitor.stages.find(x => x.slot === slot && slot >= 0) : null;
    if (!s)
        return null;
    return {op: shift ? "merge" : "activate", stage: s.id};
}

// Where a drag that started on a tile ends: x, y relative to the strip surface (the pointer stays grabbed by it outside
// the box). Beyond the right side of the surface is the stage area; a tile is that tile's stage; anything else is nothing.
function dropTarget(x, y, geo) {
    if (x >= geo.surface.w)
        return {kind: "stage"};
    for (let i = 0; i < geo.tiles.length; i++) {
        const r = geo.tiles[i];
        const rx = r.x - geo.surface.x;
        const ry = r.y - geo.surface.y;
        if (x >= rx && x < rx + r.w && y >= ry &&y < ry + r.h)
            return {kind: "tile", slot: i};
    }
    return {kind: "none"};
}

// The window a drag of tile `slot` carries: the stage's front window (the last of the list, which is back to front).
function draggedWindow(monitor, slot) {
    const s = monitor ? monitor.stages.find(x => x.slot === slot && slot >= 0) : null;
    return s && s.windows.length > 0 ? s.windows[s.windows.length - 1].address : "";
}

// Request for a drop: the dragged tile's front window goes into the active stage (drop on the stage area) or into the
// stage of another tile; a drop on its own tile or elsewhere does nothing (null).
function dropRequest(monitor, slot, target) {
    const address = draggedWindow(monitor, slot);
    if (address === "" || !monitor)
        return null;
    if (target.kind === "stage")
        return monitor.active >= 0 ? {op: "move", address: "0x" + address, stage: monitor.active} : null;
    if (target.kind === "tile" && target.slot !== slot) {
        const s = monitor.stages.find(x => x.slot === target.slot);
        return s ? {op: "move", address: "0x" + address, stage: s.id} : null;
    }
    return null;
}

// Number of windows of the stage in tile `slot`.
function windowCount(monitor, slot) {
    const s = monitor ? monitor.stages.find(x => x.slot === slot && slot >= 0) : null;
    return s ? s.windows.length : 0;
}

// Distinct app ids of a stage, front window first (the icon badge shows the first).
function appIds(stage, appIdOf) {
    const out = [];
    if (!stage)
        return out;
    for (let i = stage.windows.length - 1; i >= 0; i--) {
        const id = appIdOf(stage.windows[i].address);
        if (id !== "" && out.indexOf(id) < 0)
            out.push(id);
    }
    return out;
}
