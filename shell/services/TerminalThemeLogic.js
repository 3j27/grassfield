.pragma library

// Pure logic of TerminalTheme.qml (ADR-0045 OC-11: terminal and developer apps follow the appearance). Unit-tested in
// tests/unit/tst_terminaltheme.qml.
//
// A run is owed for a key: the effective appearance ("light" or "dark") and the Omarchy theme the settings give it, so a
// change of either (Light, Dark, Auto at its hours, another theme chosen for the appearance in use) owes one run, and the
// same key never runs twice in a row. The first key once the settings are read is the login run. Turning Match Appearance
// off forgets the last key, so turning it on again runs once. A run that failed is not retried until the key changes
// (grassfield-terminal-theme says why in the journal).

// The appearance Omarchy's theme follows.
function mode(dark) {
    return dark === true ? "dark" : "light";
}

// The key of the run the inputs owe ("dark\nTokyo Night"), or "" when none is: Match Appearance off, or grassfield.json not
// read yet. `inputs`: {on, loaded, dark, lightTheme, darkTheme}.
function key(inputs) {
    if (!inputs || inputs.on !== true || inputs.loaded !== true)
        return "";
    const m = mode(inputs.dark);
    const theme = m === "dark" ? inputs.darkTheme : inputs.lightTheme;
    return m + "\n" + (typeof theme === "string" ? theme : "");
}

// What to do now, given the inputs ({on, loaded, dark, lightTheme, darkTheme, dev, running}) and the key of the last run
// started (`last`, "" for none). Returns {action, mode, last}: `last` is the key to remember.
//   "idle"      nothing is owed (off, or not read yet): the last key is forgotten
//   "wait"      a run is going on: decide again when it ends
//   "none"      this key already ran
//   "suppress"  a dev session: nothing runs (ADR-0019 dev guard), the key counts as done so the guard logs once per change
//   "run"       run grassfield-terminal-theme <mode>
function decide(inputs, last) {
    const k = key(inputs);
    if (k === "")
        return {action: "idle", mode: "", last: ""};
    const m = mode(inputs.dark);
    if (inputs.running === true)
        return {action: "wait", mode: m, last: last};
    if (k === last)
        return {action: "none", mode: m, last: last};
    if (inputs.dev === true)
        return {action: "suppress", mode: m, last: k};
    return {action: "run", mode: m, last: k};
}

// The journal line of a finished run: the helper's status line (its first line, without control characters, at most 300
// characters) and its exit code when it is not 0.
function summary(text, exitCode) {
    let line = String(text === undefined || text === null ? "" : text).split("\n").map(s => s.trim()).find(s => s !== "") || "no answer";
    line = line.replace(/[\u0000-\u001f\u007f]/g, " ");
    if (line.length > 300)
        line = line.substring(0, 300) + "…";
    return exitCode === 0 ? line : line + " (exit " + exitCode + ")";
}
