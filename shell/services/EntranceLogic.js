.pragma library

// The session's entrance (ADR-0040 ID-20, P-3; shell/services/Entrance.qml), pure. `expected` maps a surface key
// ("wallpaper:<output>", "menubar:<output>", "dock", "icons:<output>") to whether it has its final content.

// The keys still waited for, in a stable order.
function pending(expected) {
    if (expected === null || typeof expected !== "object")
        return [];
    return Object.keys(expected).filter(k => expected[k] !== true).sort();
}

// Every expected surface is final, and at least one was expected (a shell with no surface yet never enters by itself: the
// timeout does).
function allReady(expected) {
    return expected !== null && typeof expected === "object" && Object.keys(expected).length > 0 && pending(expected).length === 0;
}

// A wallpaper key is still waited for: the entrance never comes before the wallpaper (P-3), even on its timeout; the
// wallpaper's first frame has its own bound (wallpaper.firstShowTimeoutMs), after which it shows the artwork.
function wallpaperPending(expected) {
    return pending(expected).some(k => k.indexOf("wallpaper:") === 0);
}

// `expected` without `key` (a surface that went before the entrance, e.g. an output removed). A new object.
function without(expected, key) {
    const out = Object.assign({}, expected || {});
    delete out[key];
    return out;
}

// `expected` with `key` waited for (false) unless it is already there. A new object.
function withExpected(expected, key) {
    const out = Object.assign({}, expected || {});
    if (!Object.prototype.hasOwnProperty.call(out, key))
        out[key] = false;
    return out;
}

// `expected` with `key` final. A new object.
function withReady(expected, key) {
    const out = Object.assign({}, expected || {});
    out[key] = true;
    return out;
}
