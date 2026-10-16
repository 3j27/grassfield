.pragma library

// Dock magnification math (pure, unit-tested).

// Scale of an icon whose centre is `distance` px from the pointer. Cosine falloff: `max` at 0,
// 1 at and beyond radiusIcons * pitch. A max of 1 or less disables magnification.
function scale(distance, pitch, max, radiusIcons) {
    if (max <= 1 || pitch <= 0 || radiusIcons <= 0)
        return 1;
    const reach = radiusIcons * pitch;
    const d = Math.abs(distance);
    if (d >= reach)
        return 1;
    return 1 + (max - 1) * (Math.cos(Math.PI * d / reach) + 1) / 2;
}

// Scales for icons at the given centres; pointerX < 0 (no pointer) gives all 1.
function scales(centers, pointerX, pitch, max, radiusIcons) {
    const out = [];
    for (let i = 0; i < centers.length; i++)
        out.push(pointerX < 0 ? 1 : scale(centers[i] - pointerX, pitch, max, radiusIcons));
    return out;
}

// Centres of tiles with the given widths, laid out from `left` with `spacing` between them.
function centersFor(widths, spacing, left) {
    const out = [];
    let x = left;
    for (let i = 0; i < widths.length; i++) {
        out.push(x + widths[i] / 2);
        x += widths[i] + spacing;
    }
    return out;
}

// Total width of tiles with the given widths and spacing.
function totalWidth(widths, spacing) {
    let w = 0;
    for (let i = 0; i < widths.length; i++)
        w += widths[i];
    return w + Math.max(0, widths.length - 1) * spacing;
}
