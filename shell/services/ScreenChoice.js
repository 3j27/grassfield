.pragma library

// Which screen a piece of shell UI belongs to when the screen it was opened on can go away (a monitor unplugged, a lid closed
// with an external display, a headless output removed). A screen is kept as a NAME: names are looked up in the live list every
// time they are used, never trusted from an earlier moment. Pure, unit-tested (tests/unit/tst_screenchoice.qml).

// `name` if a live screen has it, else the first live screen, else "" (no screen at all).
function resolve(name, liveNames) {
    const live = Array.isArray(liveNames) ? liveNames : [];
    if (typeof name === "string" && name !== "" && live.indexOf(name) >= 0)
        return name;
    return live.length > 0 ? live[0] : "";
}

// True when `name` is non-empty and no live screen has it any more.
function gone(name, liveNames) {
    return typeof name === "string" && name !== "" && (Array.isArray(liveNames) ? liveNames : []).indexOf(name) < 0;
}
