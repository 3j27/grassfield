.pragma library

// The screen-sharing picker's decisions (ADR-0035 D-6, step 7a; spec system-dialogs.md section 3), kept out of
// SharePicker.qml so that tests/unit/tst_sharepicker.qml reads them without Quickshell. The stand-in
// (packaging/session-bin/hyprland-share-picker) asks with `picker request <id> <socket>`; the shell connects to that socket,
// reads the window list xdph gave the stand-in, and answers one line in xdph's own grammar. The stand-in checks the answer
// again before xdph reads it: nothing here is trusted by it.

const ID = /^[0-9a-f]{32}$/;
const SOCKET = /^[0-9a-f]{32}\.sock$/;
const OUTPUT = /^[A-Za-z0-9._-]{1,64}$/;
const HANDLE = /^[0-9]{1,10}$/;
const ADDRESS = /^0x([0-9a-f]{1,16})$/;
const MAX_WINDOWS = 256;
const MAX_TEXT = 256;

// A request the shell takes: a 128-bit hex id, and a socket the stand-in made in this user's runtime directory
// ($XDG_RUNTIME_DIR/grassfield/picker/<128-bit hex>.sock). Any other path is refused: the shell connects to nothing else.
function validRequest(id, path, runtimeDir) {
    if (typeof id !== "string" || typeof path !== "string" || typeof runtimeDir !== "string")
        return false;
    if (!ID.test(id) || runtimeDir === "" || runtimeDir[0] !== "/")
        return false;
    const folder = runtimeDir.replace(/\/+$/, "") + "/grassfield/picker/";
    return path.startsWith(folder) && SOCKET.test(path.slice(folder.length));
}

// The stand-in's first line, `<id> list <json>`: the windows xdph listed, or null when the line is not that request's list.
// Each window keeps its handle (what the answer names), its app id and title (plain text, capped) and Hyprland's address
// as Compositor.toplevelByAddress takes it, lower-case hex without "0x" (the live thumbnail's source; "" when xdph had none).
function parseList(line, id) {
    const head = id + " list ";
    if (typeof line !== "string" || !line.startsWith(head))
        return null;
    let listed;
    try {
        listed = JSON.parse(line.slice(head.length));
    } catch (e) {
        return null;
    }
    if (!Array.isArray(listed))
        return null;
    const out = [];
    for (const w of listed) {
        if (out.length >= MAX_WINDOWS)
            break;
        if (!w || typeof w !== "object" || typeof w.handle !== "string" || !HANDLE.test(w.handle) || Number(w.handle) > 4294967295)
            continue;
        if (out.some(o => o.handle === w.handle))
            continue;
        out.push({
            handle: w.handle,
            appId: typeof w["class"] === "string" ? w["class"].slice(0, MAX_TEXT) : "",
            title: typeof w.title === "string" ? w.title.slice(0, MAX_TEXT) : "",
            address: typeof w.address === "string" && ADDRESS.test(w.address) ? ADDRESS.exec(w.address)[1] : ""
        });
    }
    return out;
}

// The windows in the order the Window tab shows them: grouped by app (its name), then by title.
function ordered(windows, nameFor) {
    return windows.slice().sort((a, b) => {
        const byApp = nameFor(a.appId).localeCompare(nameFor(b.appId));
        return byApp !== 0 ? byApp : a.title.localeCompare(b.title);
    });
}

// The answer line for xdph's grammar: `<flags>/screen:<output>` or `<flags>/window:<handle>`, flag "r" when the user ticked
// Remember this choice (owner decision Q14: unticked at every opening). "" for anything that is not a listed choice.
function selection(kind, value, remember, outputs, windows) {
    const flags = remember === true ? "r" : "";
    if (kind === "screen" && typeof value === "string" && OUTPUT.test(value) && outputs.indexOf(value) >= 0)
        return flags + "/screen:" + value;
    if (kind === "window" && typeof value === "string" && windows.some(w => w.handle === value))
        return flags + "/window:" + value;
    return "";
}

// What a tile stands for, kept as the selection so that it never moves to another tile when the list changes under it (a
// display plugged in, the windows sorted again once app names arrive): a display's name, a window's handle.
function keyOf(tab, tile) {
    if (!tile)
        return "";
    return tab === "screen" ? String(tile.name) : String(tile.handle);
}

// The tile of `key` in `tiles`, or -1 when it is gone (the selection then clears: Share is dimmed again).
function indexOfKey(tab, tiles, key) {
    if (key === "")
        return -1;
    for (let i = 0; i < tiles.length; i++) {
        if (keyOf(tab, tiles[i]) === key)
            return i;
    }
    return -1;
}

// The tile the arrow keys move to in a grid of `count` tiles, `columns` wide: Left/Right step, Up/Down move by a row; the
// selection stays when there is nothing that way. -1 (nothing selected) goes to the first tile.
function moved(index, key, count, columns) {
    if (count <= 0)
        return -1;
    if (index < 0 || index >= count)
        return 0;
    const cols = Math.max(1, columns);
    const to = key === "left" ? index - 1 : key === "right" ? index + 1 : key === "up" ? index - cols : key === "down" ? index + cols : index;
    return to >= 0 && to < count ? to : index;
}

// Columns that fit `width` with tiles of `tile` and gaps of `gap`, at least one.
function columnsFor(width, tile, gap) {
    return Math.max(1, Math.floor((width + gap) / (tile + gap)));
}
