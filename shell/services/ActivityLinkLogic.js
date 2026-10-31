.pragma library

// Activity Monitor's links with the shell (ADR-0038 f, AD29; docs/specs/activity.md AM60, AM61): the runtime folder of this
// display, the projection the shell writes there while the app's window is open, and the windows `activity quit` closes.
// Pure functions (tests/unit/tst_activitylink.qml).

const APP_ID = "org.grassfield.Activity";
// AM60: at most this many windows in the projection, and an app id of at most this many characters.
const MAX_WINDOWS = 256;
const MAX_APP_ID = 256;

// $XDG_RUNTIME_DIR/grassfield/activity-<display>: one folder per display (AD29: a nested session shares the real session's
// runtime directory), <display> the last part of WAYLAND_DISPLAY with every character outside [A-Za-z0-9._-] replaced by
// "_", as the clipboard helper's folder. "" without an absolute runtime directory or a display.
function runtimeDir(xdgRuntimeDir, waylandDisplay) {
    const r = String(xdgRuntimeDir || "");
    const d = String(waylandDisplay || "");
    if (r.charAt(0) !== "/" || d === "")
        return "";
    const name = d.split("/").pop().replace(/[^A-Za-z0-9._-]/g, "_");
    if (name === "")
        return "";
    return r.replace(/\/+$/, "") + "/grassfield/activity-" + name;
}

function plainPid(pid) {
    return Number.isInteger(pid) && pid > 1;
}

// The projection's body (AM60; the script that writes it adds `v` and the writer): each window with a known client pid as its
// pid, its app id and whether it inhibits idle, never its title, at most MAX_WINDOWS; and the pids NotResponding marks, each
// once. `windows`: Compositor.knownWindows(); `marks`: NotResponding.marks.
function projection(windows, marks) {
    const out = [];
    for (const w of windows || []) {
        if (out.length >= MAX_WINDOWS)
            break;
        if (!w || !plainPid(w.pid))
            continue;
        // An app id is the client's to choose: cut at the length the app reads (it refuses a longer one, AM60).
        out.push({pid: w.pid, app: String(w.cls || "").slice(0, MAX_APP_ID), idleInhibit: w.idleInhibit === true});
    }
    const hung = [];
    for (const m of marks || []) {
        if (m && plainPid(m.pid) && hung.indexOf(m.pid) < 0)
            hung.push(m.pid);
    }
    return JSON.stringify({windows: out, notResponding: hung});
}

// AM61: what `activity quit <pid>` answers before it closes anything: "refused" for a pid that is not a plain client process
// (not an integer, 0, 1 or below); "no-windows" when no window has it as its client; "ok" with the windows to close. `pids`:
// the client pid of each window, in the same order as the windows (0 when Hyprland did not report it).
function quitPlan(pid, pids) {
    if (!plainPid(pid))
        return {answer: "refused", indexes: []};
    const indexes = [];
    for (let i = 0; i < (pids || []).length; i++) {
        if (pids[i] === pid)
            indexes.push(i);
    }
    return {answer: indexes.length > 0 ? "ok" : "no-windows", indexes: indexes};
}
