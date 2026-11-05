.pragma library

// Settings > Appearance > Terminal and Developer Apps (ADR-0045 OC-11): the Light Theme and Dark Theme pop-ups list Omarchy's
// themes as `omarchy-theme-list` names them (its own themes and the user's, sorted, "Tokyo Night"). Unit-tested in
// tests/unit/tst_settingsappearance.qml.

// The theme names of omarchy-theme-list's output (one per line) that the settings accept (`valid`: a name -> bool, the rule of
// terminal.lightTheme and terminal.darkTheme), each once, in the order listed.
function parse(output, valid) {
    const out = [];
    for (const line of String(output === undefined || output === null ? "" : output).split("\n")) {
        const name = line.trim();
        if (name !== "" && out.indexOf(name) < 0 && valid(name))
            out.push(name);
    }
    return out;
}

// The pop-up's model ({id, text}): the listed themes, after the stored one when it is not among them (a theme removed since
// it was chosen: the pop-up still names the setting, as macOS shows a value it cannot list).
function choices(names, stored) {
    const list = Array.isArray(names) ? names.slice() : [];
    if (typeof stored === "string" && stored !== "" && list.indexOf(stored) < 0)
        list.unshift(stored);
    return list.map(n => ({id: n, text: n}));
}
