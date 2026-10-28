.pragma library

// Software Update (ADR-0033 d; docs/specs/updates.md U2, U4, U7, U18, U20, U22): the decisions of SoftwareUpdate.qml, pure
// (unit-tested by tests/unit/tst_softwareupdate.qml). The shell runs grassfield-update-check, a one-shot child, and keeps
// its last answer in software-update.json (version 1, ADR-0020) with the versions already announced.

const STATES = ["not-set-up", "repair", "blocking", "up-to-date", "available", "failed", "update-running", "busy"];
const SUCCESS = ["up-to-date", "available"];
// The checker caps its line at 256 KiB; anything longer is not one of its answers.
const MAX_TEXT = 300 * 1024;
const MAX_ANNOUNCED = 32;

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function iso(ms) {
    return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Milliseconds since the epoch of an ISO time, 0 when there is none.
function timeOf(value) {
    const t = Date.parse(String(value || ""));
    return isNaN(t) ? 0 : t;
}

// The checker's answer (one JSON object, version 1, a known state), or null when the text is not one.
function parse(text) {
    if (typeof text !== "string" || text.length === 0 || text.length > MAX_TEXT)
        return null;
    let o;
    try {
        o = JSON.parse(text);
    } catch (e) {
        return null;
    }
    return isObject(o) && o.version === 1 && STATES.indexOf(o.state) >= 0 ? o : null;
}

// The answer recorded for a run that gave none: it could not start, it was stopped, or what it printed was not an answer.
function noAnswer(now, message) {
    return {version: 1, state: "failed", error: "unavailable", message: message, checkedAt: iso(now)};
}

// software-update.json read back: its object with `announced` (strings, the newest last), or an empty file.
function normalize(file) {
    const f = isObject(file) && file.version === 1 ? file : {version: 1, state: ""};
    const announced = Array.isArray(f.announced) ? f.announced.filter(s => typeof s === "string").slice(-MAX_ANNOUNCED) : [];
    return Object.assign({}, f, {announced: announced});
}

// The last successful answer a file holds: its own when the last check succeeded, else the one it kept (ADR-0033 d.6).
function lastSuccess(file) {
    if (!isObject(file))
        return null;
    if (SUCCESS.indexOf(file.state) >= 0)
        return file;
    return isObject(file.previous) && SUCCESS.indexOf(file.previous.state) >= 0 ? file.previous : null;
}

function successPart(a) {
    const out = {};
    for (const k of ["state", "channel", "checkedAt", "lastSuccessAt", "grassfield", "omarchy", "others", "otherPackages", "otherPackagesTruncated"]) {
        if (a[k] !== undefined)
            out[k] = a[k];
    }
    return out;
}

// The file after an answer: the answer, the announced versions and the pending logout kept, and, when the answer is a
// failure (failed, blocking, update-running), the last successful answer as `previous`, so what was found stays shown with
// its time. not-set-up and repair keep nothing: no Grassfield repository is checked then. A busy answer (another run of
// the checker holds its lock) changes nothing: null.
function combine(file, answer) {
    if (!isObject(answer) || answer.state === "busy")
        return null;
    const f = normalize(file);
    const out = Object.assign({}, answer, {announced: f.announced});
    delete out.previous;
    delete out.logoutPending;
    if (["failed", "blocking", "update-running"].indexOf(answer.state) >= 0) {
        const last = lastSuccess(f);
        if (last)
            out.previous = successPart(last);
    }
    if (f.logoutPending === true)
        out.logoutPending = true;
    return out;
}

// The number of releases available (owner decision O3: Grassfield's and Omarchy's, 0 to 2), from the last success.
function releases(file) {
    const s = lastSuccess(file);
    if (!s || s.state !== "available")
        return 0;
    return (isObject(s.grassfield) && s.grassfield.available ? 1 : 0) + (isObject(s.omarchy) && s.omarchy.available ? 1 : 0);
}

// What an answer brings that was never announced: each Grassfield or Omarchy version found for the first time (U20), and a
// `blocking` episode (U22). [{id, kind, version, installed}].
function news(file, answer) {
    const announced = normalize(file).announced;
    const out = [];
    if (isObject(answer) && answer.state === "available") {
        for (const kind of ["grassfield", "omarchy"]) {
            const r = answer[kind];
            if (isObject(r) && r.available)
                out.push({kind: kind, version: String(r.available), installed: String(r.installed || "")});
        }
    }
    if (isObject(answer) && answer.state === "blocking" && answer.episode)
        out.push({kind: "blocking", version: String(answer.episode), installed: ""});
    return out.map(n => Object.assign(n, {id: n.kind + " " + n.version})).filter(n => announced.indexOf(n.id) < 0);
}

function withAnnounced(file, items) {
    const f = normalize(file);
    return Object.assign({}, f, {announced: f.announced.concat((items || []).map(n => n.id)).slice(-MAX_ANNOUNCED)});
}

function withLogoutPending(file, pending) {
    const out = normalize(file);
    if (pending)
        out.logoutPending = true;
    else
        delete out.logoutPending;
    return out;
}

// A package version as people read a release: "1.0.1-1" -> "1.0.1", "1.1.0beta1-3" -> "1.1.0-beta1", "2:4.0.6-1" -> "4.0.6"
// (epoch and pkgrel dropped, the hyphen of a beta or release candidate back).
function displayVersion(v) {
    const s = String(v || "").replace(/^\d+:/, "").replace(/-[^-]*$/, "");
    return s.replace(/(\d)(beta|rc)(\d+)$/, "$1-$2$3");
}

// The pkgrel when an update changes only it (a rebuild for a new Hyprland, owner decision O7), else "".
function rebuildOf(installed, available) {
    const a = String(available || ""), i = String(installed || "");
    const base = a.replace(/-[^-]*$/, "");
    return base !== "" && base !== a && base === i.replace(/-[^-]*$/, "") && a !== i ? a.substring(base.length + 1) : "";
}

// The name of a release in a sentence ("1.0.1", or "1.0.1-4" for a rebuild of the installed version).
function releaseName(available, installed) {
    const rebuild = rebuildOf(installed, available);
    return displayVersion(available) + (rebuild !== "" ? "-" + rebuild : "");
}

// The checker's argument vector (U1, U4): --offline when the shell's connectivity says offline (a failure is then not
// counted towards `blocking`), --after-update-lock for the waiter.
function checkerArgs(program, offline, waiter) {
    return [program].concat(offline ? ["--offline"] : []).concat(waiter ? ["--after-update-lock"] : []);
}

// When the next automatic check is due (U7): firstMs after the shell started, but not before intervalMs after the last
// check (a restarted shell does not check again at once); a retry the checker asked for (retryAt, the second
// [grassfield]-only sync of U3) comes first.
function nextAutomatic(startedAt, lastCheckedAt, retryAt, firstMs, intervalMs) {
    let next = startedAt + firstMs;
    if (lastCheckedAt > 0)
        next = Math.max(next, lastCheckedAt + intervalMs);
    if (retryAt > 0)
        next = Math.min(next, retryAt);
    return next;
}

// nmcli's GENERAL.METERED answer: "yes" or "yes (guessed)" is metered; anything else, an empty or unreadable answer
// included, is not.
function metered(text) {
    return /^yes/m.test(String(text || ""));
}
