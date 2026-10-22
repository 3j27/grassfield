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

// Processes to kill for "Force Quit" on an app's tile (Option variant of Quit): the distinct client PIDs of its windows. PIDs that
// are not plain client processes (unknown 0, init 1, negatives, non-integers) are dropped, as Power.forceQuit refuses them.
function forceQuitPids(pids) {
    const out = [];
    for (const p of pids || []) {
        if (Number.isInteger(p) && p > 1 && out.indexOf(p) < 0)
            out.push(p);
    }
    return out;
}

// Window list at the top of an app's Dock menu (macOS): one row per window of the app, the most recent first. Each window is
// {ref, title, minimized, stamp}; a row is {ref, title (whitespace collapsed, elided to `max` characters, the app name when
// empty), minimized, checked}. The check goes to the most recently focused window that is not minimized (macOS: the key window);
// a minimized window never has it. Choosing a row activates that one window (Compositor.activate restores a minimized window
// and switches to its Desktop, the same call as a Dock click).
function menuWindows(windows, max, appName) {
    if (!windows || windows.length === 0)
        return [];
    const sorted = windows.slice().sort((a, b) => b.stamp - a.stamp);
    const front = sorted.find(w => !w.minimized);
    return sorted.map(w => {
        const t = String(w.title === undefined || w.title === null ? "" : w.title).replace(/\s+/g, " ").trim();
        const title = t === "" ? appName : t;
        return {
            ref: w.ref,
            title: title.length > max ? title.slice(0, max - 1) + "…" : title,
            minimized: w.minimized === true,
            checked: w === front
        };
    });
}
