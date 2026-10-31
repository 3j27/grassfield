.pragma library

// Software Update (ADR-0033 d; docs/specs/updates.md U2, U4, U7, U18-U22): the decisions of the shell's SoftwareUpdate.qml and
// of Settings' Software Update pane, pure (unit-tested by tests/unit/tst_softwareupdate.qml). The shell runs
// grassfield-update-check, a one-shot child, and keeps its last answer in software-update.json (version 1, ADR-0020) with the
// versions already announced; Settings reads that file.

const STATES = ["not-set-up", "repair", "blocking", "up-to-date", "available", "failed", "update-running", "busy"];
// A check that worked: `not-set-up` too, which lists the system's updates without Grassfield's (ADR-0033 "Step 2 as built").
const SUCCESS = ["up-to-date", "available", "not-set-up"];
// The answers that carry releases.
const LISTING = ["available", "not-set-up"];
// The checker caps its line at 256 KiB; anything longer is not one of its answers.
const MAX_TEXT = 300 * 1024;
const MAX_ANNOUNCED = 32;
// software-update.json holds one answer and the last success kept beside it: anything much longer is not the shell's file.
const MAX_FILE = 1024 * 1024;
const CHANNELS = ["stable", "beta", "custom", "repair", "off"];

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
// its time. not-set-up (a success without Grassfield's repository) and repair keep nothing. A busy answer (another run of
// the checker holds its lock) changes nothing: null.
function combine(file, answer) {
    if (!isObject(answer) || answer.state === "busy")
        return null;
    const f = normalize(file);
    const out = Object.assign({}, answer, {announced: f.announced});
    delete out.previous;
    delete out.logoutPending;
    delete out.toolkitLogout;
    if (["failed", "blocking", "update-running"].indexOf(answer.state) >= 0) {
        const last = lastSuccess(f);
        if (last)
            out.previous = successPart(last);
    }
    // An answer given before the checker ran (busy, update-running) or by no checker (noAnswer) carries no toolkit: the
    // file's list stays, so the pane's sentence does not fall back meanwhile (the integrator's review of 9043ac4, nit 7).
    if (out.toolkit === undefined && f.toolkit !== undefined)
        out.toolkit = f.toolkit;
    if (f.toolkitAsked !== undefined)
        out.toolkitAsked = f.toolkitAsked;
    if (f.logoutPending === true)
        out.logoutPending = true;
    if (f.toolkitLogout === true)
        out.toolkitLogout = true;
    return out;
}

// The number of releases available (owner decision O3: Grassfield's and Omarchy's, 0 to 2), from the last success; with
// Grassfield updates off (not-set-up), Omarchy's still counts.
function releases(file) {
    const s = lastSuccess(file);
    if (!s || LISTING.indexOf(s.state) < 0)
        return 0;
    return (isObject(s.grassfield) && s.grassfield.available ? 1 : 0) + (isObject(s.omarchy) && s.omarchy.available ? 1 : 0);
}

// ADR-0041 step 2b (U31): the toolkit as the checker lists it ([{name, installed, installedAt, built, moved}]); [] when the
// answer (or the file) carries no list (an older checker, a `busy` or `update-running` answer before the file kept one).
function toolkitPackages(answer) {
    const t = isObject(answer) && isObject(answer.toolkit) && Array.isArray(answer.toolkit.packages) ? answer.toolkit.packages : [];
    return t.filter(p => isObject(p) && typeof p.name === "string" && p.name !== "" && typeof p.installed === "string");
}

// The installed versions a log out was already asked for on an install time the checker could not read ({name: installed},
// the file's `toolkitAsked`): asked once, then not again for the same installed version (a pacman database outside its
// default path has no readable entry; without this every session would ask again).
function toolkitAsked(file) {
    const a = isObject(file) && isObject(file.toolkitAsked) ? file.toolkitAsked : {};
    const out = {};
    for (const k of Object.keys(a)) {
        if (typeof a[k] === "string")
            out[k] = a[k];
    }
    return out;
}

// The packages replaced under the running session: installed at or after `sessionStartMs`, or at a time the checker could
// not read and not asked for yet (`asked`, the safe side: a log out asked for nothing is a nuisance, a session kept on a
// library that was replaced is a crash waiting). Whatever the build's record says: a pkgrel rebuild replaces the file too.
// A package installed before the session started is what the session already runs on: no log out for it.
function toolkitReplaced(answer, sessionStartMs, asked) {
    const a = asked || {};
    return toolkitPackages(answer).filter(p => {
        const at = timeOf(p.installedAt);
        return at > 0 ? at >= sessionStartMs : a[p.name] !== p.installed;
    });
}

function toolkitLogout(answer, sessionStartMs, asked) {
    return toolkitReplaced(answer, sessionStartMs, asked).length > 0;
}

// The file with the packages of `replaced` whose install time could not be read recorded as asked for.
function withToolkitAsked(file, replaced) {
    const out = normalize(file);
    const a = toolkitAsked(out);
    for (const p of replaced || []) {
        if (!(timeOf(p.installedAt) > 0))
            a[p.name] = p.installed;
    }
    out.toolkitAsked = a;
    return out;
}

// The packages that moved away from the record this Grassfield was built with (U27's rule): for the log line, never for a
// sentence (the integrator's decision on #77: macOS never names libraries in an update notice).
function toolkitMoved(answer) {
    return toolkitPackages(answer).filter(p => p.moved === true);
}

// The session's start, in ms: Hyprland's own, from HYPRLAND_INSTANCE_SIGNATURE ("<hash>_<unix seconds>_<n>"), the same
// across a restart of the shell (a shell restarted after an upgrade would otherwise date the upgrade before its own start
// and ask for nothing, while the compositor keeps running on the replaced libraries); never later than `fallbackMs` (the
// shell's start: a later signature would hide installs), and `fallbackMs` without a signature or with one of another shape.
function sessionStart(signature, fallbackMs) {
    const m = /^[0-9a-fA-F]+_([0-9]{9,11})_[0-9]+$/.exec(String(signature || ""));
    const t = m ? Number(m[1]) * 1000 : 0;
    return t > 0 ? Math.min(t, fallbackMs) : fallbackMs;
}

// What an answer brings that was never announced: each Grassfield or Omarchy version found for the first time (U20), a
// `blocking` episode (U22), and a toolkit replaced under the running session (U31: once per session, whatever the versions,
// the id carries the session's start and the `announced` list survives a restart of the shell). [{id, kind, version, installed}].
function news(file, answer, sessionStartMs) {
    const announced = normalize(file).announced;
    const out = [];
    if (isObject(answer) && LISTING.indexOf(answer.state) >= 0) {
        for (const kind of ["grassfield", "omarchy"]) {
            const r = answer[kind];
            if (isObject(r) && r.available)
                out.push({kind: kind, version: String(r.available), installed: String(r.installed || "")});
        }
    }
    if (isObject(answer) && answer.state === "blocking" && answer.episode)
        out.push({kind: "blocking", version: String(answer.episode), installed: ""});
    if (toolkitLogout(answer, sessionStartMs, toolkitAsked(file)))
        out.push({kind: "toolkit", version: String(sessionStartMs), installed: ""});
    return out.map(n => Object.assign(n, {id: n.kind + " " + n.version})).filter(n => announced.indexOf(n.id) < 0);
}

function withAnnounced(file, items) {
    const f = normalize(file);
    return Object.assign({}, f, {announced: f.announced.concat((items || []).map(n => n.id)).slice(-MAX_ANNOUNCED)});
}

// Two flags: `pending`, GF-083's own log out (Grassfield itself was updated in this session); `toolkit`, a toolkit package
// replaced under the session (U31). The pane words its row by them: "Log out to finish updating Grassfield" for the first,
// "Log out to finish updating" for the second alone.
function withLogoutPending(file, pending, toolkit) {
    const out = normalize(file);
    if (pending)
        out.logoutPending = true;
    else
        delete out.logoutPending;
    if (toolkit)
        out.toolkitLogout = true;
    else
        delete out.toolkitLogout;
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

// software-update.json's text as Settings reads it: its object (normalize), or an empty file when the text is missing, too
// long or not JSON.
function fromText(text) {
    if (typeof text !== "string" || text.length === 0 || text.length > MAX_FILE)
        return normalize(null);
    try {
        return normalize(JSON.parse(text));
    } catch (e) {
        return normalize(null);
    }
}

// What `grassfield-channel-set` printed (its first line): stable, beta, custom, repair or off; "" for anything else.
function channelOf(text) {
    const c = String(text || "").split("\n")[0].trim();
    return CHANNELS.indexOf(c) >= 0 ? c : "";
}

// The build can set Grassfield updates up (grassfield-channel-set's require_build, docs/specs/updates.md Refusals): its
// repository.conf names a signing key and a base that is file:// or a host outside .invalid.
function buildReady(repositoryConf) {
    const value = key => {
        for (const line of String(repositoryConf || "").split("\n")) {
            if (line.indexOf(key + "=") === 0)
                return line.substring(key.length + 1).trim();
        }
        return "";
    };
    const base = value("GRASSFIELD_REPO_BASE");
    if (value("GRASSFIELD_SIGNING_FINGERPRINT") === "" || base === "")
        return false;
    if (base.indexOf("file://") === 0)
        return true;
    const m = /^https:\/\/([^/:]+)/.exec(base);
    return m !== null && m[1] !== "invalid" && !/\.invalid$/.test(m[1]);
}

// The release notes in the session's language (U6): [{version, date, text}], newest first as the checker lists them; French
// when the UI is French and the release has it, English otherwise.
function notesFor(grassfield, uiLanguage) {
    const notes = isObject(grassfield) && Array.isArray(grassfield.notes) ? grassfield.notes : [];
    const french = String(uiLanguage || "").indexOf("fr") === 0;
    const out = [];
    for (const r of notes) {
        if (!isObject(r) || !isObject(r.notes))
            continue;
        const text = french && typeof r.notes.fr === "string" && r.notes.fr !== "" ? r.notes.fr : r.notes.en;
        if (typeof text === "string" && text !== "")
            out.push({version: String(r.version || ""), date: String(r.date || ""), text: text});
    }
    return out;
}

// What Settings' pane shows (U2, U21, U22): `kind` is the file's state, or "checking" while a check runs, or "never" before a
// first answer; the releases come from the last success (kept through a failure, an update and `blocking`);
// `repair` is true in the repair state and on a custom channel (U13).
function view(file, checking) {
    const f = normalize(file);
    const s = lastSuccess(f);
    const known = STATES.indexOf(f.state) >= 0 && f.state !== "busy";
    const channel = s && s.channel ? s.channel : (f.channel || "");
    const others = s && typeof s.others === "number" && s.others > 0 ? s.others : 0;
    const listing = s !== null && LISTING.indexOf(s.state) >= 0;
    return {
        kind: checking ? "checking" : known ? f.state : "never",
        error: f.state === "failed" ? String(f.error || "unavailable") : "",
        message: typeof f.message === "string" ? f.message : "",
        checkedAt: timeOf(f.checkedAt),
        lastSuccessAt: s ? timeOf(s.checkedAt) : 0,
        channel: channel,
        repair: f.state === "repair" || channel === "custom",
        grassfield: listing && isObject(s.grassfield) && s.grassfield.available ? s.grassfield : null,
        omarchy: listing && isObject(s.omarchy) && s.omarchy.available ? s.omarchy : null,
        installed: {
            grassfield: s && isObject(s.grassfield) ? String(s.grassfield.installed || "") : "",
            omarchy: s && isObject(s.omarchy) ? String(s.omarchy.installed || "") : ""
        },
        others: listing ? others : 0,
        otherPackages: listing && Array.isArray(s.otherPackages) ? s.otherPackages : [],
        otherPackagesTruncated: s && s.otherPackagesTruncated === true
    };
}

// The file holds a new answer: its checkedAt is not the one it had before (a pending logout written alone is no answer).
function answered(before, after) {
    const a = normalize(after).checkedAt;
    return typeof a === "string" && a !== "" && a !== normalize(before).checkedAt;
}

// --- Update Now without a terminal (ADR-0033 "Step 3", owner decision SU-M1; docs/specs/updates.md U24-U30) ---------------
// grassfield-update-run's state ($XDG_RUNTIME_DIR/grassfield/software-update-run.json) and grassfield-update-helper's files
// (/run/grassfield-update/<op>.progress, .exit, .started), read by Settings.
const RUN_PHASES = ["authorizing", "configuring", "done"];
const RUN_RESULTS = ["up-to-date", "done", "failed-partial", "busy", "space", "power", "incompatible", "terminal", "stalelock",
    "failed", "cancelled", "denied", "bootimage"];
const HELPER_PHASES = ["checking", "snapshot", "keyring", "downloading", "installing", "finishing"];
const MAX_RUN_TEXT = 4096;

// The runner's state, or null when the text is not one.
function parseRun(text) {
    if (typeof text !== "string" || text === "" || text.length > MAX_RUN_TEXT)
        return null;
    let v;
    try {
        v = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!isObject(v) || v.version !== 1 || !/^[0-9a-f]{32}$/.test(String(v.op)) || RUN_PHASES.indexOf(v.phase) < 0)
        return null;
    const result = typeof v.result === "string" ? v.result : "";
    if (v.phase === "done" ? RUN_RESULTS.indexOf(result) < 0 : result !== "")
        return null;
    return {
        op: v.op,
        pid: Number.isInteger(v.pid) && v.pid > 0 ? v.pid : 0,
        startTime: /^[0-9]{1,20}$/.test(String(v.startTime)) ? String(v.startTime) : "",
        phase: v.phase,
        result: result,
        restart: v.restart === "restart" || v.restart === "logout" ? v.restart : "",
        snapshot: v.snapshot === "made" || v.snapshot === "none" || v.snapshot === "failed" ? v.snapshot : "",
        // The checked sync databases became the system's before the run stopped: "nothing was changed" is then not said.
        synced: v.synced === true,
        deferred: Array.isArray(v.deferred) ? v.deferred.filter(d => d === "migrations" || d === "aur") : [],
        startedAt: typeof v.startedAt === "number" ? v.startedAt : 0,
        finishedAt: typeof v.finishedAt === "number" ? v.finishedAt : 0
    };
}

// Field 22 of /proc/<pid>/stat (the start time); "" when unreadable. The command name before it is in parentheses and may
// hold spaces and parentheses.
function startTimeOf(statText) {
    const s = String(statText || "");
    const close = s.lastIndexOf(") ");
    if (close < 0)
        return "";
    const fields = s.slice(close + 2).trim().split(/\s+/);
    return fields.length > 19 && /^[0-9]+$/.test(fields[19]) ? fields[19] : "";
}

// The helper's progress line: {phase, done, total}, or null.
function parseProgress(text) {
    const parts = String(text || "").trim().split(/\s+/);
    if (HELPER_PHASES.indexOf(parts[0]) < 0)
        return null;
    const done = parts.length === 3 && /^[0-9]{1,6}$/.test(parts[1]) ? Number(parts[1]) : 0;
    const total = parts.length === 3 && /^[0-9]{1,6}$/.test(parts[2]) ? Number(parts[2]) : 0;
    return { phase: parts[0], done: Math.min(done, total), total: total };
}

// The overall percentage of a run (ADR-0033 s3.5): 0-5 checking and the snapshot, 5-45 downloading, 45-95 installing,
// 95-100 finishing and Omarchy's steps for the user; -1 when nothing is counted (an indeterminate bar).
function percentOf(phase, done, total) {
    const part = total > 0 ? done / total : -1;
    switch (phase) {
    case "downloading":
        return part < 0 ? -1 : Math.round(5 + 40 * part);
    case "installing":
        return part < 0 ? -1 : Math.round(45 + 50 * part);
    case "finishing":
        return 95;
    case "configuring":
        return 97;
    }
    return -1;
}

// What the pane shows of a run: {state, phase, done, total, percent, result, restart, snapshot, synced, deferred}. `state`: "none",
// "running" (authorizing, the helper's phases, configuring) or "done". `run`: parseRun's; `alive`: the runner's process is
// still the one the state names; `progress`: parseProgress of the helper's file for run.op; `helperAlive`: the helper of
// run.op still runs (its .started process). A runner that ended without its last state (a log out) shows the helper while
// it runs, then nothing.
function runView(run, alive, progress, helperAlive) {
    const none = { state: "none", phase: "", done: 0, total: 0, percent: -1, result: "", restart: "", snapshot: "", synced: false, deferred: [] };
    if (run === null)
        return none;
    if (run.phase === "done")
        return { state: "done", phase: "done", done: 0, total: 0, percent: -1, result: run.result, restart: run.restart, snapshot: run.snapshot,
            synced: run.synced === true, deferred: run.deferred };
    if (!alive && !helperAlive)
        return none;
    let phase = run.phase === "configuring" ? "configuring" : progress !== null ? progress.phase : "authorizing";
    if (run.phase === "authorizing" && !alive && progress === null)
        phase = "checking";
    const done = phase === "downloading" || phase === "installing" ? progress.done : 0;
    const total = phase === "downloading" || phase === "installing" ? progress.total : 0;
    return { state: "running", phase: phase, done: done, total: total, percent: percentOf(phase, done, total), result: "", restart: "", snapshot: "",
        synced: false, deferred: [] };
}

// The run the helper's `last` names, when no runner's state is left (a log out ended the runner and its runtime folder, a new
// session opened Settings): {op, phase: "authorizing"} for runView with the runner not alive, or null for a text that is not
// an operation id.
function helperRun(lastText) {
    const op = String(lastText || "").trim();
    if (!/^[0-9a-f]{32}$/.test(op))
        return null;
    return { op: op, pid: 0, startTime: "", phase: "authorizing", result: "", restart: "", snapshot: "", synced: false, deferred: [], startedAt: 0, finishedAt: 0 };
}
