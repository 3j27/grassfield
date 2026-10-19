.pragma library

// Pointer outline and fill colours (Settings > Accessibility > Pointer, ADR-0014). Pure functions, no I/O, shared by the
// Settings app (validation, colour maths) and the shell (theme regeneration plan, what it asks the compositor for).
// The two colours are the two placeholders of the SVG sources in branding/cursors/src ({{OUTLINE}}, {{FILL}}); the
// defaults are the packaged theme's own, so default colours never regenerate anything. Like macOS, any colour is
// allowed (no contrast guard).

const DEFAULT_OUTLINE = "#ffffff";
const DEFAULT_FILL = "#000000";
// The packaged theme (default colours) and the one regenerated at runtime (custom colours).
const BASE_THEME = "grassfield-cursors";
const CUSTOM_THEME = "grassfield-cursors-custom";

function validColor(value) {
    return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value);
}

// A stored value (any JSON type) to a colour: lower-case #rrggbb, else the fallback.
function normalize(value, fallback) {
    return validColor(value) ? value.toLowerCase() : fallback;
}

function normalizeOutline(value) {
    return normalize(value, DEFAULT_OUTLINE);
}

function normalizeFill(value) {
    return normalize(value, DEFAULT_FILL);
}

function isDefault(outline, fill) {
    return normalizeOutline(outline) === DEFAULT_OUTLINE && normalizeFill(fill) === DEFAULT_FILL;
}

// Identity of a colour pair ("" for the default pair, which has no custom theme).
function key(outline, fill) {
    return isDefault(outline, fill) ? "" : normalizeOutline(outline) + "|" + normalizeFill(fill);
}

// The theme the compositor should use for the colours, given the theme the session selected: the session theme for the
// default pair, the regenerated one otherwise.
function themeFor(outline, fill, sessionTheme) {
    return isDefault(outline, fill) ? sessionTheme : CUSTOM_THEME;
}

// ---- regeneration (branding/cursors/build.sh) ----

// Directory the custom theme is written into: GRASSFIELD_CURSORS_ICONS (the dev session sets it under .dev/), else
// $XDG_DATA_HOME/icons, else $HOME/.local/share/icons. "" when there is none, or in a dev session that was given no
// isolated directory (the owner's icons are never written from a dev session). hyprcursor and XCursor search
// $HOME/.local/share/icons and $XDG_DATA_DIRS, so an XDG_DATA_HOME elsewhere is only found when it is also in
// XDG_DATA_DIRS.
function iconsDir(override, dataHome, home, dev) {
    if (typeof override === "string" && override !== "")
        return override;
    if (dev)
        return "";
    if (typeof dataHome === "string" && dataHome !== "")
        return dataHome + "/icons";
    if (typeof home === "string" && home !== "")
        return home + "/.local/share/icons";
    return "";
}

// Argument vector that builds the custom theme, [] for an invalid colour, script or directory. No shell is involved:
// every value is one argv element (the colours are validated, the theme name is fixed).
function buildCommand(script, dir, outline, fill) {
    if (typeof script !== "string" || script === "" || typeof dir !== "string" || dir === "")
        return [];
    if (!validColor(outline) || !validColor(fill))
        return [];
    return ["bash", script, "--out", dir, "--name", CUSTOM_THEME, "--outline", outline.toLowerCase(), "--fill", fill.toLowerCase()];
}

// Argument vector that deletes the custom theme (Reset Color).
function removeCommand(script, dir) {
    if (typeof script !== "string" || script === "" || typeof dir !== "string" || dir === "")
        return [];
    return ["bash", script, "--remove", "--out", dir, "--name", CUSTOM_THEME];
}

// One short line for the Settings pane from what a failed build printed: the last non-empty line of stderr, at most 160
// characters, control characters removed; exit 127 (no script) and an empty message have their own text.
function failureReason(exitCode, stderrText) {
    if (exitCode === 127)
        return "the cursor builder is not installed";
    const lines = String(stderrText || "").split("\n").map(l => l.replace(/[\u0000-\u001f\u007f]/g, " ").trim()).filter(l => l !== "");
    const last = lines.length > 0 ? lines[lines.length - 1] : "";
    return last !== "" ? last.substring(0, 160) : "the cursor builder failed (exit " + exitCode + ")";
}

// ---- build scheduling: one build at a time, the newest colours win ----
//
// State {wanted, running, built, failed, terminating}: colour pair keys ("" = none). The caller (shell/platform/Pointer
// Theme.qml) keeps the state, calls these functions on its events and carries out the returned action. No timers here.

function initialState() {
    return {wanted: "", running: "", built: "", failed: "", terminating: false};
}

function copy(state) {
    return {wanted: state.wanted, running: state.running, built: state.built, failed: state.failed, terminating: state.terminating};
}

// New wanted pair (after the debounce). A different pair forgets an older failure.
function want(state, wantedKey) {
    const next = copy(state);
    next.wanted = wantedKey;
    if (next.failed !== wantedKey)
        next.failed = "";
    return next;
}

// What to do now: "start" (begin a build of `wanted`), "terminate" (the running build is for older colours), or "none".
function decide(state) {
    if (state.wanted === "")
        return state.running !== "" && !state.terminating ? "terminate" : "none";
    if (state.running !== "") {
        if (state.running !== state.wanted && !state.terminating)
            return "terminate";
        return "none";
    }
    if (state.wanted !== state.built && state.wanted !== state.failed)
        return "start";
    return "none";
}

// The custom theme was deleted: nothing is built any more (the same pair chosen again must build again).
function forgetBuilt(state) {
    const next = copy(state);
    next.built = "";
    return next;
}

function started(state) {
    const next = copy(state);
    next.running = state.wanted;
    next.terminating = false;
    return next;
}

function terminating(state) {
    const next = copy(state);
    next.terminating = true;
    return next;
}

// The build process ended. A terminated build produced nothing worth keeping; a finished one is built or failed.
function exited(state, ok) {
    const next = copy(state);
    if (!state.terminating) {
        if (ok)
            next.built = state.running;
        else
            next.failed = state.running;
    }
    next.running = "";
    next.terminating = false;
    return next;
}

// ---- colour maths for the Settings colour well ----

function clamp01(v) {
    return Math.max(0, Math.min(1, v));
}

function hex2(n) {
    const s = Math.round(Math.max(0, Math.min(255, n))).toString(16);
    return s.length < 2 ? "0" + s : s;
}

// h, s, v in 0..1 to "#rrggbb".
function fromHsv(h, s, v) {
    h = clamp01(h);
    s = clamp01(s);
    v = clamp01(v);
    const i = Math.floor(h * 6) % 6;
    const f = h * 6 - Math.floor(h * 6);
    const p = v * (1 - s);
    const q = v * (1 - f * s);
    const t = v * (1 - (1 - f) * s);
    const rgb = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i];
    return "#" + hex2(rgb[0] * 255) + hex2(rgb[1] * 255) + hex2(rgb[2] * 255);
}

// "#rrggbb" to {h, s, v} in 0..1; null for an invalid colour.
function toHsv(color) {
    if (!validColor(color))
        return null;
    const r = parseInt(color.substring(1, 3), 16) / 255;
    const g = parseInt(color.substring(3, 5), 16) / 255;
    const b = parseInt(color.substring(5, 7), 16) / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const d = max - min;
    let h = 0;
    if (d > 0) {
        if (max === r)
            h = ((g - b) / d + 6) % 6;
        else if (max === g)
            h = (b - r) / d + 2;
        else
            h = (r - g) / d + 4;
        h /= 6;
    }
    return {h: h, s: max === 0 ? 0 : d / max, v: max};
}

// Typed text to a colour: "#rrggbb", "rrggbb" or "#rgb", else "".
function parseTyped(text) {
    let t = String(text || "").trim();
    if (t.charAt(0) === "#")
        t = t.substring(1);
    if (/^[0-9a-fA-F]{3}$/.test(t))
        t = t.charAt(0) + t.charAt(0) + t.charAt(1) + t.charAt(1) + t.charAt(2) + t.charAt(2);
    return /^[0-9a-fA-F]{6}$/.test(t) ? "#" + t.toLowerCase() : "";
}
