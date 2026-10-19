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

// The theme the compositor should use for the colours, given the theme the session selected: the packaged theme for the
// default pair, the regenerated one otherwise. It follows the stored colours only, never the session environment: a
// session that was started with the custom theme (it was on disk at login) still goes back to the packaged theme when the
// colours are the defaults. A theme that is not ours (a session that does not use Grassfield's cursors) is left alone.
function themeFor(outline, fill, sessionTheme) {
    if (!isDefault(outline, fill))
        return CUSTOM_THEME;
    return baseTheme(sessionTheme);
}

// The theme for the default colours: the packaged one, whatever Grassfield theme the session started with; "" when the
// session has no cursor theme at all (nothing to ask the compositor for); a foreign theme stays as it is.
function baseTheme(sessionTheme) {
    if (typeof sessionTheme !== "string" || sessionTheme === "")
        return "";
    return sessionTheme === CUSTOM_THEME ? BASE_THEME : sessionTheme;
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

// File inside the custom theme that names the colours it was built for: one line "#outline #fill" (build.sh writes it).
function stampPath(dir) {
    return typeof dir === "string" && dir !== "" ? dir + "/" + CUSTOM_THEME + "/colors" : "";
}

// The colour key of a stamp file's text ("" when it is missing, empty or not exactly two #rrggbb colours).
function parseStamp(text) {
    const m = /^(#[0-9a-fA-F]{6}) (#[0-9a-fA-F]{6})\s*$/.exec(String(text || ""));
    return m ? key(m[1], m[2]) : "";
}

// Argument vector that builds the custom theme, [] for an invalid colour, script or directory. No shell is involved:
// every value is one argv element (the colours are validated, the theme name is fixed). setsid makes the build the
// leader of its own process group, so the shell can stop the build and everything it started (kill -- -PID).
function buildCommand(script, dir, outline, fill) {
    if (typeof script !== "string" || script === "" || typeof dir !== "string" || dir === "")
        return [];
    if (!validColor(outline) || !validColor(fill))
        return [];
    return ["setsid", "bash", script, "--out", dir, "--name", CUSTOM_THEME, "--outline", outline.toLowerCase(), "--fill", fill.toLowerCase()];
}

// Argument vector that deletes the custom theme (Reset Color).
function removeCommand(script, dir) {
    if (typeof script !== "string" || script === "" || typeof dir !== "string" || dir === "")
        return [];
    return ["bash", script, "--remove", "--out", dir, "--name", CUSTOM_THEME];
}

// Argument vector that deletes the work directories of builds that are no longer running (startup).
function cleanCommand(script, dir) {
    if (typeof script !== "string" || script === "" || typeof dir !== "string" || dir === "")
        return [];
    return ["bash", script, "--clean", "--out", dir, "--name", CUSTOM_THEME];
}

// Argument vector that stops a process group (the build and its children): `kill -s SIGNAL -- -PID`. [] unless the
// signal is TERM (15) or KILL (9) and the PID is a plain number above 1.
function groupSignalCommand(signal, pid) {
    if ((signal !== 15 && signal !== 9) || typeof pid !== "number" || !Number.isInteger(pid) || pid <= 1)
        return [];
    return ["kill", "-s", signal === 15 ? "TERM" : "KILL", "--", "-" + pid];
}

// One short line for the Settings pane from what a failed build printed: the last non-empty line of stderr, at most 160
// characters (cut with an ellipsis), the home folder written "~", control characters removed; exit 127 (no script) and
// an empty message have their own text.
function failureReason(exitCode, stderrText, home) {
    if (exitCode === 127)
        return "the cursor builder is not installed";
    const lines = String(stderrText || "").split("\n").map(l => l.replace(/[\u0000-\u001f\u007f]/g, " ").trim()).filter(l => l !== "");
    const last = lines.length > 0 ? lines[lines.length - 1] : "";
    if (last === "")
        return "the cursor builder failed (exit " + exitCode + ")";
    const short = tildeHome(last, home);
    return short.length > 160 ? short.substring(0, 159) + "…" : short;
}

// Writes the home folder as "~" (only where it is a whole path prefix: followed by "/" or the end, after a space or the
// start or a quote or a colon). No home (or "/"): unchanged.
function tildeHome(text, home) {
    const h = typeof home === "string" ? home.replace(/\/+$/, "") : "";
    if (h === "" || h.charAt(0) !== "/")
        return text;
    const escaped = h.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return text.replace(new RegExp("(^|[\\s'\"=:(])" + escaped + "(?=/|$|[\\s'\":)])", "g"), "$1~");
}

// What kind of failure it was, for the Settings pane to say in its own language: "builder" (no script: exit 127),
// "tool:NAME" (build.sh: "cursors: NAME not found"), "failed" otherwise. (The tool's own message is shown apart.)
function failureCode(exitCode, stderrText) {
    if (exitCode === 127)
        return "builder";
    const lines = String(stderrText || "").split("\n").map(l => l.trim()).filter(l => l !== "");
    const m = /^cursors: ([A-Za-z0-9_-]+) not found$/.exec(lines.length > 0 ? lines[lines.length - 1] : "");
    return m ? "tool:" + m[1] : "failed";
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

// The build process ended. A finished one is built or failed. A terminated build (or one that failed half-way) may have
// replaced the theme just before it stopped: what is on disk is not known until the stamp is read (onDisk).
function exited(state, ok) {
    const next = copy(state);
    if (!state.terminating) {
        if (ok)
            next.built = state.running;
        else
            next.failed = state.running;
    }
    if (state.terminating || !ok)
        next.built = "";
    next.running = "";
    next.terminating = false;
    return next;
}

// The stamp of the theme on disk was read: `diskKey` is the colour pair it was built for ("" = no theme, or no stamp).
// The theme counts as built only for exactly that pair.
function onDisk(state, diskKey) {
    const next = copy(state);
    next.built = typeof diskKey === "string" ? diskKey : "";
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
