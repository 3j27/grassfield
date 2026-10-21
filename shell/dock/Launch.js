.pragma library

// Launch and activation rules of the Dock (pure functions, tested in tests/unit/tst_docklaunch.qml).
//
// Launch state of one tile: idle -> launching (click on an app with no window) -> running (its first window mapped) or
// idle again (timeout, or the tile is gone). The state is the `launching` map: key -> start time (ms); a key that is
// absent is idle.

// State of a tile: "idle", "launching" or "running" (a window exists, whatever the map says).
function stateOf(launching, key, windowCount, now, timeoutMs) {
    if (windowCount > 0)
        return "running";
    const started = launching ? launching[key] : undefined;
    if (started === undefined || now - started > timeoutMs)
        return "idle";
    return "launching";
}

// A click on a tile with no window. {start, launching}: `start` is false (and the map unchanged) while the tile is
// already launching, so a double click never starts the app twice.
function click(launching, key, now, timeoutMs) {
    if (stateOf(launching, key, 0, now, timeoutMs) === "launching")
        return {start: false, launching: launching};
    const next = Object.assign({}, launching ? launching : {});
    next[key] = now;
    return {start: true, launching: next};
}

// Windows to activate when a running app is clicked, in the order to activate them: the last one ends focused and in
// front. Each window is {ref, minimized, here (on the focused Desktop), stamp (recency, higher is more recent)}.
//   - visible windows on this Desktop: all of them come forward, the most recent last (macOS: every window of the app);
//   - none here: the most recent visible window (the Desktop switches to it);
//   - everything minimized: only the most recent one is restored.
function activationPlan(windows) {
    if (!windows || windows.length === 0)
        return [];
    const byRecency = (a, b) => a.stamp - b.stamp;
    const visible = windows.filter(w => !w.minimized);
    if (visible.length === 0) {
        const last = windows.slice().sort(byRecency).pop();
        return [last.ref];
    }
    const here = visible.filter(w => w.here);
    if (here.length > 0)
        return here.slice().sort(byRecency).map(w => w.ref);
    return [visible.slice().sort(byRecency).pop().ref];
}
