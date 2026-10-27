.pragma library

// "Not responding" (ADR-0035 D-3, step 3): the decisions of NotResponding.qml, pure (unit-tested by
// tests/unit/tst_notresponding.qml). Hyprland runs `hyprland-dialog` when an app misses its pings; Grassfield's stand-in
// (packaging/session-bin/hyprland-dialog) finds the app's process and reports it (`anr report`); the shell marks it in Force
// Quit and the Dock menu while the stand-in lives (the macOS model: no alert).

// A string argument of the stand-in carries a prefix ("c:" class, "t:" title, "i:" Hyprland instance): `qs ipc` takes an
// argument that starts with "-" for an option. The value without it, or null when the prefix is missing.
function unprefix(value, prefix) {
    const s = String(value === undefined || value === null ? "" : value);
    return s.startsWith(prefix) ? s.substring(prefix.length) : null;
}

// Whether to accept a report. `windows` are the windows the shell knows: {pid (0 when not known yet), cls, title}.
// Refused: a pid that is not a plain client process (unknown 0, init 1), an empty class, a report from another compositor
// (a nested session's stand-in reaching this shell), or windows with this class and title that belong to another process
// (two processes of one app with the same title: the stand-in could not tell them apart either). A window the shell does
// not know yet does not refuse: the stand-in found it in Hyprland's own list. {ok, reason}.
function decide(standin, pid, cls, title, instance, ownInstance, windows) {
    if (!(Number.isInteger(standin) && standin > 1))
        return {ok: false, reason: "standin"};
    if (!(Number.isInteger(pid) && pid > 1))
        return {ok: false, reason: "pid"};
    if (cls === null || cls === "" || title === null)
        return {ok: false, reason: "window"};
    if (instance === null || instance === "" || instance !== ownInstance)
        return {ok: false, reason: "instance"};
    for (const w of windows || []) {
        if (w.cls === cls && w.title === title && w.pid > 0 && w.pid !== pid)
            return {ok: false, reason: "ambiguous"};
    }
    return {ok: true, reason: ""};
}

// The marks with this one added: one per stand-in. A process can have several (Hyprland runs one dialog per XWayland
// surface, ANRManager.cpp:155-158); it is marked while any of them lives.
function withMark(marks, mark) {
    return (marks || []).filter(m => m.standin !== mark.standin).concat([mark]);
}

function withoutStandin(marks, standin) {
    return (marks || []).filter(m => m.standin !== standin);
}

function isMarked(marks, pid) {
    return pid > 1 && (marks || []).some(m => m.pid === pid);
}

// The marked pids among `pids` (an app's windows), without repeats.
function markedAmong(marks, pids) {
    const out = [];
    for (const p of pids || []) {
        if (isMarked(marks, p) && out.indexOf(p) < 0)
            out.push(p);
    }
    return out;
}

// Force Quit, at the confirmation: the pid still owns a window of the class the user chose (one class from the Force Quit
// panel, the classes of the app's windows from its Dock menu): the pid was not reused by another process in between. No
// class (an old caller) is not checked.
function stillOwns(windows, pid, cls) {
    if (!(pid > 1))
        return false;
    const classes = (Array.isArray(cls) ? cls : [cls]).filter(c => typeof c === "string" && c !== "");
    if (classes.length === 0)
        return true;
    return (windows || []).some(w => w.pid === pid && classes.indexOf(w.cls) >= 0);
}

// The row of the Force Quit list that is selected when it opens: the first not-responding app's, else the first.
function initialIndex(rowPids, marks) {
    for (let i = 0; i < (rowPids || []).length; i++) {
        if (isMarked(marks, rowPids[i]))
            return i;
    }
    return rowPids && rowPids.length > 0 ? 0 : -1;
}

// Force Quit's selection after its window list or the marks changed (ADR-0035 decision 3-13). `kept` is the row of the
// window selected before (-1 when it is gone or there was none), `preferred` initialIndex's row, `preferredMarked` whether
// that app does not respond. The user's own choice is kept, by window (-1 when that window is gone: nothing is selected and
// Force Quit is off). Before the user moved, the selection goes onto an app that does not respond, else stays on the window
// it was on, else the first row: a mark that clears never moves it away from the app the user was shown.
function selectionAfterChange(userMoved, kept, preferred, preferredMarked) {
    if (userMoved)
        return kept;
    if (preferred >= 0 && preferredMarked)
        return preferred;
    return kept >= 0 ? kept : preferred;
}

// What `anr status` shows, in a dev session only (it holds window titles: private state, security.md "IPC surface").
function statusJson(marks) {
    return JSON.stringify((marks || []).map(m => ({standin: m.standin, pid: m.pid, cls: m.cls, title: m.title})));
}
