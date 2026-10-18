.pragma library

// Launch helpers of Apps.qml (docs/specs/dock.md, "Dev notes: isolated app launches"). Pure functions.

// Environment that isolates the config, cache and state of every app launched from a GRASSFIELD_DEV session
// (XDG_DATA_DIRS stays: system desktop entries and icons must still resolve; XDG_DATA_HOME is isolated too).
function isolatedEnvironment(appsHome) {
    return {
        "XDG_CONFIG_HOME": appsHome + "/config",
        "XDG_CACHE_HOME": appsHome + "/cache",
        "XDG_STATE_HOME": appsHome + "/state",
        "XDG_DATA_HOME": appsHome + "/data"
    };
}

// Directory of the isolated homes: `<dev>/apps-home`, where <dev> is the parent of GRASSFIELD_STATE_HOME
// (scripts/dev/shell-run.sh passes `<dev>/state`); `fallbackBase` (a scratch directory) when it is unset.
function appsHomeFor(stateHome, fallbackBase) {
    const s = String(stateHome || "").replace(/\/+$/, "");
    const i = s.lastIndexOf("/");
    if (i > 0)
        return s.substring(0, i) + "/apps-home";
    return fallbackBase + "/grassfield-dev/apps-home";
}

// argv of a desktop entry or action `command` (QStringList): Exec field codes (%f %F %u %U %i %c %k and
// the deprecated ones) are dropped, "%%" is a literal percent. [] when nothing is left.
function stripFieldCodes(command) {
    const out = [];
    for (const arg of Array.from(command || [])) {
        const a = String(arg);
        if (/^%[a-zA-Z]$/.test(a))
            continue;
        out.push(a.replace(/%(.)/g, (m, c) => c === "%" ? "%" : ""));
    }
    return out;
}

// What an "open this in an application" helper command asks for (dev open policy, ADR-0011).
//   gio open T...   xdg-open T   gtk-launch APP [T...]  -> { targets: [T...] }
//   gio launch ...  gtk-launch APP (no target)          -> { refuse: "application launch" }
//   any other command (gio trash, nm-connection-editor)  -> null: not an open request, runs as given.
function openRequest(argv) {
    const a = Array.from(argv || []).map(String);
    const name = a.length > 0 ? a[0].replace(/^.*\//, "") : "";
    if (name === "gio" && a[1] === "open")
        return a.length > 2 ? {"targets": a.slice(2)} : {"refuse": "nothing to open"};
    if (name === "gio" && a[1] === "launch")
        return {"refuse": "application launch"};
    if (name === "xdg-open")
        return a.length > 1 ? {"targets": a.slice(1)} : {"refuse": "nothing to open"};
    if (name === "gtk-launch")
        return a.length > 2 ? {"targets": a.slice(2)} : {"refuse": "application launch"};
    return null;
}
