.pragma library

// Why the compositor extension is absent, and what the shell does about it (ADR-0009 "Amendment 2026-10-23", audit
// GF-033). The session loader only loads a build made for the Hyprland that runs and writes the journal; the shell asks
// `grassfield-compositor-rebuild --status` (and, with the opt-in setting windows.rebuildExtension, `--session`) and
// turns the key=value lines they print into a translated notice. Pure: no process, no file access.

// The values the shell shows or acts on: short tokens, never free text.
const valueMax = 64;
const known = ["state", "result", "reason", "version"];

// key=value lines -> {state, result, reason, version}; unknown keys, malformed lines and odd values are dropped.
function parse(text) {
    const out = {state: "", result: "", reason: "", version: ""};
    if (typeof text !== "string")
        return out;
    for (const line of text.split("\n")) {
        const eq = line.indexOf("=");
        if (eq <= 0)
            continue;
        const key = line.slice(0, eq).trim();
        const value = line.slice(eq + 1).trim();
        if (known.indexOf(key) < 0 || out[key] !== "")
            continue;
        if (value.length === 0 || value.length > valueMax || !/^[A-Za-z0-9._-]+$/.test(value))
            continue;
        out[key] = value;
    }
    return out;
}

// The degraded notice: "mismatch" when no build is made for the installed Hyprland (the rebuild is the recovery), else
// "absent" (the plain notice: the check is unavailable, or a build matches and was not loaded).
function notice(status) {
    return status && status.state === "mismatch" ? "mismatch" : "absent";
}

// The shell starts `--session` once per shell run: on a mismatch, with the opt-in setting on.
function rebuilds(status, settingOn, tried) {
    return settingOn === true && tried !== true && notice(status) === "mismatch";
}

// The outcome of `--session`: "loaded" (built if needed and loaded into the running Hyprland), "built" (log out and back
// in), "cannot-build" (tools, sources, cache or another build), "failed" (the build failed, or no answer).
function outcome(status) {
    if (!status)
        return "failed";
    if (status.result === "loaded" || status.result === "built")
        return status.result;
    if (status.result === "failed" && status.reason === "cannot-build")
        return "cannot-build";
    return "failed";
}

// The Hyprland version a notice names; "" when the script did not give one.
function version(status) {
    return status && status.version !== "unknown" ? status.version : "";
}
