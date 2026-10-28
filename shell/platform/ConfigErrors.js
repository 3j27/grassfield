.pragma library

// Hyprland's config errors (ADR-0035 D-2, step 3): the decisions of ConfigErrors.qml, pure (unit-tested by
// tests/unit/tst_configerrors.qml). The shell shows one notice per new set of errors. Hyprland's red error bar stays on: on
// 0.56.2 under the Lua config `hyprctl configerrors` is always empty (ADR-0035 decision 3-15), so no notice shows there.

// The most error lines a notice lists; the rest are counted ("and 2 more").
const shownLines = 3;

// The error lines of a `hyprctl -j configerrors` answer: a JSON array of strings, `[""]` when there is none (Hyprland
// 0.56.2 src/debug/HyprCtl.cpp:725-746). Blank lines and repeats are dropped. Anything else (no Hyprland, an error text) is
// null: no answer, nothing changes.
function parse(text) {
    let value;
    try {
        value = JSON.parse(String(text === undefined || text === null ? "" : text));
    } catch (e) {
        return null;
    }
    if (!Array.isArray(value) || value.some(v => typeof v !== "string"))
        return null;
    const out = [];
    for (const v of value) {
        const line = v.trim();
        if (line !== "" && out.indexOf(line) < 0)
            out.push(line);
    }
    return out;
}

// One key per set of errors: the same set after a reload is not announced again.
function key(errors) {
    return (errors || []).join("\n");
}

// What to do with a read: "post" a notice for a new non-empty set, "clear" the notice when the errors are gone, else
// "keep". `shownKey` is the key of the set the notice on screen is for ("" when there is none).
function action(errors, shownKey) {
    if (errors === null)
        return "keep";
    const k = key(errors);
    if (k === "")
        return shownKey === "" ? "keep" : "clear";
    return k === shownKey ? "keep" : "post";
}

// The notice's body: the lines, then `rest` ("and 2 more") when given, as text. A notification body is markup, where Lua's
// "'end' expected near <eof>" would lose "<eof>" as a tag: "&" and "<" are escaped.
function noticeBody(lines, rest) {
    const text = l => String(l).replace(/&/g, "&amp;").replace(/</g, "&lt;");
    return (lines || []).concat(rest ? [rest] : []).map(text).join("\n");
}

// The lines the notice lists, and how many it leaves out.
function summary(errors) {
    const all = errors || [];
    return {
        lines: all.slice(0, shownLines),
        more: Math.max(0, all.length - shownLines)
    };
}
