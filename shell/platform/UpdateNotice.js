.pragma library

// "Log out to finish updating" (GF-083; macOS: "Restart to finish installing"). A package update replaces the files on
// disk, but the running session keeps the old compositor plugin (Hyprland never unloads it; the loaded library stays in
// memory) and the old shell until the next login. The shell compares what it runs with what is installed.
//
//   installed  /usr/share/grassfield/VERSION (written by the package; absent in older packages)
//   shell      the same file as the shell read it at its start
//   plugin     the "version" field of the plugin's `grassfield` hyprctl reply (absent in plugins that predate it)
//
// Capability check: a missing or unreadable piece means "unknown", and unknown never shows the notice. Pure: no process,
// no file access (tests/unit/tst_updatenotice.qml).

const valueMax = 64;

// A version as it is written in the file or the reply: short, printable, no spaces. "" when it is not one.
function clean(text) {
    if (typeof text !== "string")
        return "";
    const v = text.trim();
    // "unknown" (and its like) is what a build without a version id reports: it is not a version, it is no information.
    if (/^(unknown|none|null|undefined|dev|0)$/i.test(v))
        return "";
    return v.length > 0 && v.length <= valueMax && /^[A-Za-z0-9._+~-]+$/.test(v) ? v : "";
}

// First line of the VERSION file.
function fromFile(text) {
    return typeof text === "string" ? clean(text.split("\n")[0]) : "";
}

// The plugin version of the reply ({"v":"gfc/1","type":"capabilities","features":[...],"version":"..."}), "" when the
// reply is not that or carries no version (an older plugin).
function fromReply(text) {
    if (typeof text !== "string")
        return "";
    let doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return "";
    }
    if (doc === null || typeof doc !== "object" || doc.type !== "capabilities")
        return "";
    return clean(doc.version);
}

// Same version despite spelling: pacman writes 1.0.0rc1, the VERSION file 1.0.0-rc1.
function same(a, b) {
    const x = clean(a).toLowerCase().replace(/[^a-z0-9]/g, "");
    const y = clean(b).toLowerCase().replace(/[^a-z0-9]/g, "");
    return x !== "" && x === y;
}

// True when a piece that is known differs from the installed version. Unknown pieces ("") never count.
function pending(installed, shell, plugin) {
    if (clean(installed) === "")
        return false;
    return (clean(shell) !== "" && !same(installed, shell)) || (clean(plugin) !== "" && !same(installed, plugin));
}
