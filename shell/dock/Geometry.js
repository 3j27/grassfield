.pragma library

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
