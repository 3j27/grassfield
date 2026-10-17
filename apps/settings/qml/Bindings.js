.pragma library

// Read-only parser for the Grassfield bindings file (config/hypr/grassfield/bindings.lua):
// extracts the literal `bind("KEYS", "Description", ...)` lines. Loops and computed keys are skipped.

const BIND = /^\s*bind\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"/;

const NAMES = {
    "SUPER": "Super", "CTRL": "Ctrl", "ALT": "Alt", "SHIFT": "Shift", "RETURN": "Return", "SPACE": "Space",
    "TAB": "Tab", "ESCAPE": "Esc", "UP": "Up", "DOWN": "Down", "LEFT": "Left", "RIGHT": "Right",
    "mouse:272": "Left Mouse Button", "mouse:273": "Right Mouse Button"
};

function unescapeLua(s) {
    return s.replace(/\\(["\\])/g, "$1");
}

function prettyKey(token) {
    const t = token.trim();
    if (NAMES[t] !== undefined)
        return NAMES[t];
    return t.length === 1 ? t.toUpperCase() : t;
}

function prettyKeys(keys) {
    return keys.split("+").map(prettyKey).join(" + ");
}

// Returns [{keys, description}] in file order; duplicate (keys, description) pairs are dropped.
function parse(text) {
    const out = [];
    const seen = {};
    for (const line of String(text).split("\n")) {
        if (/^\s*--/.test(line))
            continue;
        const m = BIND.exec(line);
        if (!m)
            continue;
        const keys = prettyKeys(unescapeLua(m[1]));
        const description = unescapeLua(m[2]);
        const id = keys + "\u0000" + description;
        if (seen[id])
            continue;
        seen[id] = true;
        out.push({keys: keys, description: description});
    }
    return out;
}
