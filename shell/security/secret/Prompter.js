.pragma library

// prompter/1, the shell's side (ADR-0035 D-9, step 9b; docs/specs/system-dialogs.md section 5, "prompter/1 protocol").
// Pure: no Quickshell and no QML type, so tests/security/tst_prompter.qml checks every rule without a socket.
//
// What the bridge sends is read strictly: a line that is not exactly one of its messages, with the right keys and types,
// closes the connection (fail closed: the bridge then answers every outstanding request "cancelled" and releases
// org.gnome.keyring.SystemPrompter until the shell connects again). A "cancel" for an id the shell does not hold is
// ignored (it crossed the shell's own answer). Nothing here invents an answer: answerLine() builds the one line the shell
// sends for a request, and refuses (returns "") what the bridge would refuse.

var PROTOCOL = "prompter/1";
// The kinds this shell draws, its hello's "kinds" (the bridge never sends another): gcr's password and confirm,
// NetworkManager's secrets (nm, step 9c) and KIO's network passwords (kio, step 9e); bluetooth comes with step 10.
var KINDS = ["password", "confirm", "nm", "kio"];
// Secret requests the shell holds at once, shown or waiting (ADR-0035 D-9: the ninth is answered "cancelled").
var MAX_REQUESTS = 8;
// A bridge line longer than this (UTF-16 code units, the newline excluded) closes the connection. The longest prompt the
// bridge can send, every text at its cap and every character escaped, stays under 7000.
var MAX_BRIDGE_LINE = 16384;
// A shell line: at most 16 KiB of UTF-8, the newline excluded (bridges/prompter/src/Protocol.h limits::kShellLine).
var MAX_SHELL_LINE = 16384;
// A password: at most 4096 bytes of UTF-8 (limits::kPassword; the bridge cancels a longer one).
var MAX_PASSWORD_BYTES = 4096;
// A kio answer's name (identity, step 9e): at most 1024 bytes of UTF-8 (limits::kIdentity). An nm answer never carries one.
var MAX_IDENTITY_BYTES = 1024;
// The securities of an nm request (bridges/prompter/src/NmSecrets.h): WPA/WPA2 Personal, WPA3 Personal, WEP, WPA2 Enterprise.
var SECURITIES = ["wpa", "wpa3", "wep", "enterprise"];
// The bridge's caps (bridges/prompter/src/Text.h, ADR-0035 decision 9-11), UTF-16 code units, the ellipsis included.
var CAPS = {
    title: 128,
    message: 256,
    description: 1024,
    warning: 256,
    button: 32,
    choice: 128,
    name: 128,
    icon: 256,
    desktopId: 256,
    path: 512,
    version: 64,
    error: 256,
    ssid: 64,
    identity: 256,
    server: 262,
    realm: 256
};
// "disk": grassfield-askpass, udiskie's password command (step 9c); "kio": KIO's worker executable (step 9e).
var ROLES = ["app", "keyring", "gnupg", "ssh", "disk", "kio", "unidentified"];
// Programs that ask for others: the text under their row is another program's, unverified (spec SC3b, decision 9-14);
// grassfield-askpass runs for whoever starts it, with a disk name of theirs; KIO's worker runs any worker plugin it is given.
var ON_BEHALF = ["keyring", "gnupg", "ssh", "disk", "kio"];
// A kio request's fields (step 9e): the name field's modes, Remember this password's states, the keyring's protection.
var NAME_MODES = ["edit", "fixed", "none"];
var REMEMBER_STATES = ["none", "off", "on"];
var KEYRING_STATES = ["protected", "unprotected", "unknown"];
// The server of a kio request: a host name (lower-case letters, digits, '-', '_', dots) or an IPv6 address in brackets, then
// an optional port: never free text (the bridge's KioAuth.h serverLabel; decision 9-42).
var SERVER_PATTERN = /^(?:[a-z0-9_-]{1,63}(?:\.[a-z0-9_-]{1,63})*\.?|\[[0-9a-f:.]{2,45}\])(?::[0-9]{1,5})?$/;
var NAME_STATES = ["released", "queued", "owned"];
// Waits before the next connection attempt: 1 s, doubling, at most 30 s (a bridge that is restarting, or not there).
var RETRY_FIRST_MS = 1000;
var RETRY_MAX_MS = 30000;

// --- plain text (decision 9-13, the bridge's rule: bridges/prompter/src/Text.cpp) ----------------------------------------

// Shows nothing itself and changes how the text around it is shown, or is not a character at all: removed.
function removedCodePoint(c) {
    return c === 0x00AD || c === 0x034F || c === 0x061C || c === 0x180E || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E)
        || (c >= 0x2060 && c <= 0x2064) || (c >= 0x2066 && c <= 0x2069) || c === 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB)
        || (c >= 0xE0000 && c <= 0xE007F) || (c >= 0xFDD0 && c <= 0xFDEF) || (c & 0xFFFE) === 0xFFFE;
}

// Control characters, DEL, C1, the line and paragraph separators and Qt's white space (QChar::isSpace: tab to carriage
// return, U+0085, U+00A0 and the Zs, Zl and Zp separators): one space between words, none at either end.
function spaceCodePoint(c) {
    return c < 0x20 || (c >= 0x7F && c <= 0x9F) || c === 0x20 || c === 0xA0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200A)
        || c === 0x2028 || c === 0x2029 || c === 0x202F || c === 0x205F || c === 0x3000;
}

// Untrusted text as one plain line of at most `cap` UTF-16 code units, the ellipsis included: what the bridge already did
// to it (the shell does it again, so a broken bridge cannot draw more; the result of the bridge's rule is unchanged by it).
// Unpaired surrogates become U+FFFD; the cut never splits a pair and drops the spaces before the ellipsis.
function flatten(text, cap) {
    if (typeof text !== "string" || !(cap > 0))
        return "";
    let out = "";
    let pendingSpace = false;
    for (let i = 0; i < text.length && out.length <= cap + 2; i++) {
        let c = text.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xDC00 && text.charCodeAt(i + 1) <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (text.charCodeAt(i + 1) - 0xDC00);
            i++;
        } else if (c >= 0xD800 && c <= 0xDFFF) {
            c = 0xFFFD;
        }
        if (spaceCodePoint(c)) {
            pendingSpace = out.length > 0;
            continue;
        }
        if (removedCodePoint(c))
            continue;
        if (pendingSpace) {
            out += " ";
            pendingSpace = false;
        }
        out += String.fromCodePoint(c);
    }
    if (out.length <= cap)
        return out;
    let cut = cap - 1;
    if (cut > 0 && out.charCodeAt(cut - 1) >= 0xD800 && out.charCodeAt(cut - 1) <= 0xDBFF)
        cut--;
    out = out.slice(0, cut);
    while (out.length > 0 && out.charCodeAt(out.length - 1) === 0x20)
        out = out.slice(0, -1);
    return out + "\u2026";
}

// UTF-8 bytes of a string as JSON.stringify writes it (an unpaired surrogate is written as a 6-byte \u escape).
function utf8Length(text) {
    let n = 0;
    for (let i = 0; i < text.length; i++) {
        const c = text.charCodeAt(i);
        if (c < 0x80)
            n += 1;
        else if (c < 0x800)
            n += 2;
        else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xDC00 && text.charCodeAt(i + 1) <= 0xDFFF) {
            n += 4;
            i++;
        } else if (c >= 0xD800 && c <= 0xDFFF)
            n += 6;
        else
            n += 3;
    }
    return n;
}

// --- the connection -------------------------------------------------------------------------------------------------

function isAbsolute(path) {
    return typeof path === "string" && path.length > 1 && path.charAt(0) === "/" && path.indexOf("\0") < 0 && path.indexOf("\n") < 0;
}

// The bridge's socket. Outside a dev session (ADR-0019): $XDG_RUNTIME_DIR/grassfield/prompter.sock, where
// grassfield-prompter listens (an absolute runtime directory, else none). In a dev session only the test socket its caller
// names (absolute), else none: a dev shell never reaches the user's own bridge, and nothing changes the real session's path.
function socketPath(dev, runtimeDir, devSocket) {
    if (dev === true)
        return isAbsolute(devSocket) ? devSocket : "";
    if (!isAbsolute(runtimeDir))
        return "";
    let dir = runtimeDir;
    while (dir.length > 1 && dir.charAt(dir.length - 1) === "/")
        dir = dir.slice(0, -1);
    return dir + "/grassfield/prompter.sock";
}

// The wait before attempt `failures` + 1 (failures counts the attempts that ended without the bridge's hello).
function retryDelay(failures) {
    const n = Math.max(0, Math.min(failures | 0, 16));
    return Math.min(RETRY_MAX_MS, RETRY_FIRST_MS * Math.pow(2, n));
}

// --- bridge -> shell -------------------------------------------------------------------------------------------------

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// The object has exactly these keys, no other.
function exactKeys(o, keys) {
    const own = Object.keys(o);
    if (own.length !== keys.length)
        return false;
    for (let i = 0; i < keys.length; i++) {
        if (!Object.prototype.hasOwnProperty.call(o, keys[i]))
            return false;
    }
    return true;
}

function isString(v, cap) {
    return typeof v === "string" && v.length <= cap;
}

// A request id the bridge hands out: "p" and a decimal number without a leading zero, at most 20 characters.
function validId(id) {
    return typeof id === "string" && /^p[1-9][0-9]{0,18}$/.test(id);
}

function failure(reason) {
    return {ok: false, reason: reason};
}

// One line of the bridge, the newline excluded. `helloSeen`: the bridge's hello came before. Returns {ok: true, message}
// (message.type: hello, name, prompt, cancel, error) or {ok: false, reason}: the shell then closes the connection.
function parseBridgeLine(line, helloSeen) {
    if (typeof line !== "string")
        return failure("not text");
    if (line.length > MAX_BRIDGE_LINE)
        return failure("a line over " + MAX_BRIDGE_LINE + " characters");
    let m;
    try {
        m = JSON.parse(line);
    } catch (e) {
        return failure("not JSON");
    }
    if (!isObject(m) || typeof m.type !== "string")
        return failure("not a message");
    if (m.type === "hello")
        return helloSeen ? failure("hello repeated") : parseHello(m);
    // The bridge's refusals (refused, busy, version) come instead of its hello, then it closes the connection.
    if (m.type === "error")
        return parseError(m);
    if (!helloSeen)
        return failure("a message before hello");
    if (m.type === "name")
        return parseName(m);
    if (m.type === "prompt")
        return parsePrompt(m);
    if (m.type === "cancel")
        return parseCancel(m);
    return failure("an unknown message type");
}

function parseHello(m) {
    if (!exactKeys(m, ["v", "type", "bridge", "kinds", "max"]))
        return failure("hello: unexpected keys");
    if (m.v !== PROTOCOL)
        return failure("hello: protocol " + flatten(String(m.v), CAPS.version) + " is not " + PROTOCOL);
    if (!isString(m.bridge, CAPS.version) || !Array.isArray(m.kinds) || m.kinds.length > 16 || !m.kinds.every(k => isString(k, 64))
            || typeof m.max !== "number" || m.max !== Math.floor(m.max) || m.max < 1 || m.max > 64)
        return failure("hello: wrong types");
    return {ok: true, message: {type: "hello", bridge: flatten(m.bridge, CAPS.version), kinds: m.kinds.slice(), max: m.max}};
}

function parseName(m) {
    if (!exactKeys(m, ["type", "state"]) || NAME_STATES.indexOf(m.state) < 0)
        return failure("name: wrong shape");
    return {ok: true, message: {type: "name", state: m.state}};
}

function parseCancel(m) {
    if (!exactKeys(m, ["type", "id"]) || !validId(m.id))
        return failure("cancel: wrong shape");
    return {ok: true, message: {type: "cancel", id: m.id}};
}

function parseError(m) {
    if (!exactKeys(m, ["type", "code", "message"]) || !isString(m.code, 64) || typeof m.message !== "string")
        return failure("error: wrong shape");
    return {ok: true, message: {type: "error", code: flatten(m.code, 64), text: flatten(m.message, CAPS.error)}};
}

// A prompt: every key the bridge sends (Protocol.cpp promptMessage), the right types, texts within the bridge's caps,
// the requester consistent with its role (only "app" has a name; identified for all but "unidentified"; on behalf of
// others for keyring, gnupg, ssh and disk), the kinds this shell draws, passwordNew and strength only for a password.
function parsePrompt(m) {
    if (m.kind === "nm")
        return parseNetworkPrompt(m);
    if (m.kind === "kio")
        return parseServerPrompt(m);
    if (!exactKeys(m, ["type", "id", "kind", "requester", "texts", "choice", "passwordNew", "strength"]))
        return failure("prompt: unexpected keys");
    if (!validId(m.id))
        return failure("prompt: invalid id");
    if (KINDS.indexOf(m.kind) < 0)
        return failure("prompt: a kind this shell does not draw");
    const requester = parseRequester(m.requester);
    if (typeof requester === "string")
        return failure("prompt: " + requester);
    const t = m.texts;
    if (!isObject(t) || !exactKeys(t, ["title", "message", "description", "warning", "continue", "cancel"]))
        return failure("prompt: texts have unexpected keys");
    if (!isString(t.title, CAPS.title) || !isString(t.message, CAPS.message) || !isString(t.description, CAPS.description)
            || !isString(t.warning, CAPS.warning) || !isString(t["continue"], CAPS.button) || !isString(t.cancel, CAPS.button))
        return failure("prompt: texts have wrong types or lengths");
    let choice = null;
    if (m.choice !== null) {
        const c = m.choice;
        if (!isObject(c) || !exactKeys(c, ["label", "chosen"]) || !isString(c.label, CAPS.choice) || typeof c.chosen !== "boolean"
                || flatten(c.label, CAPS.choice) === "")
            return failure("prompt: choice has a wrong shape");
        choice = {label: flatten(c.label, CAPS.choice), chosen: c.chosen};
    }
    if (typeof m.passwordNew !== "boolean" || typeof m.strength !== "boolean" || m.strength !== m.passwordNew
            || (m.kind !== "password" && m.passwordNew))
        return failure("prompt: passwordNew or strength inconsistent");
    return {
        ok: true,
        message: {
            type: "prompt",
            id: m.id,
            kind: m.kind,
            requester: requester,
            texts: {
                title: flatten(t.title, CAPS.title),
                message: flatten(t.message, CAPS.message),
                description: flatten(t.description, CAPS.description),
                warning: flatten(t.warning, CAPS.warning),
                continueLabel: flatten(t["continue"], CAPS.button),
                cancelLabel: flatten(t.cancel, CAPS.button)
            },
            choice: choice,
            passwordNew: m.passwordNew,
            strength: m.strength
        }
    };
}

// The requester object the bridge resolved from the caller's credentials (a gcr prompt's, a kio request's): exactly its
// keys, the right types, within the caps, consistent with its role (only "app" has a name; identified for all but
// "unidentified"; on behalf of others for keyring, gnupg, ssh, disk and kio). The requester read, or a string saying what is
// wrong.
function parseRequester(r) {
    if (!isObject(r) || !exactKeys(r, ["role", "name", "desktopId", "icon", "path", "identified", "onBehalf"]))
        return "requester has unexpected keys";
    if (ROLES.indexOf(r.role) < 0 || !isString(r.name, CAPS.name) || !isString(r.desktopId, CAPS.desktopId) || !isString(r.icon, CAPS.icon)
            || !isString(r.path, CAPS.path) || typeof r.identified !== "boolean" || typeof r.onBehalf !== "boolean")
        return "requester has wrong types";
    if (r.identified !== (r.role !== "unidentified") || r.onBehalf !== (ON_BEHALF.indexOf(r.role) >= 0)
            || (r.role === "app") !== (flatten(r.name, CAPS.name) !== ""))
        return "requester inconsistent with its role";
    return {
        role: r.role,
        name: r.role === "app" ? flatten(r.name, CAPS.name) : "",
        desktopId: flatten(r.desktopId, CAPS.desktopId),
        icon: r.role === "app" ? flatten(r.icon, CAPS.icon) : "",
        path: flatten(r.path, CAPS.path),
        identified: r.identified,
        onBehalf: r.onBehalf
    };
}

// KIO's request (kind kio, step 9e; Protocol.cpp kioPromptMessage): exactly its keys; the requester as a gcr prompt's; the
// server a host name and its port only (SERVER_PATTERN), shown as a quoted field of Grassfield's sentence; the name field's
// first text and mode; the realm (the server's own words, plain, shown framed as unverified); retry; Remember this password
// and the keyring's protection (none without Remember). No caller text otherwise, no check box of the caller's.
function parseServerPrompt(m) {
    if (!exactKeys(m, ["type", "id", "kind", "requester", "server", "login"]))
        return failure("kio prompt: unexpected keys");
    if (!validId(m.id))
        return failure("kio prompt: invalid id");
    const requester = parseRequester(m.requester);
    if (typeof requester === "string")
        return failure("kio prompt: " + requester);
    if (typeof m.server !== "string" || m.server.length > CAPS.server || !SERVER_PATTERN.test(m.server))
        return failure("kio prompt: a server that is not a host name");
    const l = m.login;
    if (!isObject(l) || !exactKeys(l, ["name", "nameMode", "realm", "retry", "remember", "keyring"]))
        return failure("kio prompt: login has unexpected keys");
    if (!isString(l.name, CAPS.identity) || NAME_MODES.indexOf(l.nameMode) < 0 || !isString(l.realm, CAPS.realm) || typeof l.retry !== "boolean"
            || REMEMBER_STATES.indexOf(l.remember) < 0 || KEYRING_STATES.indexOf(l.keyring) < 0)
        return failure("kio prompt: login has wrong types");
    if ((l.nameMode === "none" && l.name !== "") || (l.remember === "none" && l.keyring !== "unknown"))
        return failure("kio prompt: login inconsistent");
    return {
        ok: true,
        message: {
            type: "prompt",
            id: m.id,
            kind: "kio",
            requester: requester,
            texts: {title: "", message: "", description: "", warning: "", continueLabel: "", cancelLabel: ""},
            choice: null,
            passwordNew: false,
            strength: false,
            server: m.server,
            login: {
                name: flatten(l.name, CAPS.identity),
                nameMode: l.nameMode,
                realm: flatten(l.realm, CAPS.realm),
                retry: l.retry,
                remember: l.remember,
                keyring: l.keyring
            }
        }
    };
}

// NetworkManager's request (kind nm, step 9c; Protocol.cpp nmPromptMessage): exactly its keys, the SSID shown (plain,
// within its cap, not empty), a known security, a name only for enterprise. The bridge sends this kind only for a call
// from the current owner of org.freedesktop.NetworkManager: the requester row is the shell's own ("Wi-Fi", asked by
// NetworkManager), built here as the fixed role "network", never from anything the request carries. The rest of the
// message has the shape of a gcr prompt with nothing in it (no caller text, no check box), so the sheet's rules apply.
function parseNetworkPrompt(m) {
    if (!exactKeys(m, ["type", "id", "kind", "network"]))
        return failure("nm prompt: unexpected keys");
    if (!validId(m.id))
        return failure("nm prompt: invalid id");
    const n = m.network;
    if (!isObject(n) || !exactKeys(n, ["ssid", "security", "identity"]))
        return failure("nm prompt: network has unexpected keys");
    if (!isString(n.ssid, CAPS.ssid) || SECURITIES.indexOf(n.security) < 0 || !isString(n.identity, CAPS.identity))
        return failure("nm prompt: network has wrong types");
    const ssid = flatten(n.ssid, CAPS.ssid);
    if (ssid === "")
        return failure("nm prompt: an SSID that shows nothing");
    if (n.security !== "enterprise" && n.identity !== "")
        return failure("nm prompt: a name for a network that asks for none");
    // An enterprise network's username is shown, never asked (NetworkManager keeps only secrets from an agent's reply):
    // the bridge sends one only with the connection's own (opus review of step 9c, MAJOR).
    if (n.security === "enterprise" && flatten(n.identity, CAPS.identity) === "")
        return failure("nm prompt: an enterprise network without its username");
    return {
        ok: true,
        message: {
            type: "prompt",
            id: m.id,
            kind: "nm",
            requester: {role: "network", name: "", desktopId: "", icon: "", path: "", identified: true, onBehalf: false},
            texts: {title: "", message: "", description: "", warning: "", continueLabel: "", cancelLabel: ""},
            choice: null,
            passwordNew: false,
            strength: false,
            network: {ssid: ssid, security: n.security, identity: flatten(n.identity, CAPS.identity)}
        }
    };
}

// A Wi-Fi password the sheet may send, from its length in UTF-16 code units (never the text): WPA/WPA2 Personal takes
// 8 to 63 characters or 64 hexadecimal digits (NetworkManager checks the rest); the other securities any non-empty one.
function networkLengthOk(security, length) {
    if (!(length > 0))
        return false;
    return security === "wpa" ? length >= 8 && length <= 64 : SECURITIES.indexOf(security) >= 0;
}

// --- shell -> bridge -------------------------------------------------------------------------------------------------

// The shell's hello: the first line, once.
function helloLine(version) {
    return JSON.stringify({v: PROTOCOL, type: "hello", shell: flatten(String(version), CAPS.version), kinds: KINDS});
}

// The one answer to `request` (a parsed prompt, or what the client kept of it: id, kind, passwordNew, choice, security,
// nameMode, remember):
// "ok" with the password for a password request (a string, "" only for a new password) and the check box's state when
// the prompt had one; for an nm request the password only (not empty: NetworkManager keeps nothing else of a reply, opus
// review of step 9c); "cancel" carries no password. `identity` is sent only for a kio request whose sheet asks a name
// (step 9e), never for nm.
// Returns the line, or "" when it would be wrong (no password for an ok password answer, one over MAX_PASSWORD_BYTES, a
// line over MAX_SHELL_LINE): nothing is sent then.
function answerLine(request, ok, password, choice, identity) {
    if (!isObject(request) || !validId(request.id) || KINDS.indexOf(request.kind) < 0)
        return "";
    const m = {type: "answer", id: request.id, result: ok === true ? "ok" : "cancel"};
    if (request.kind === "kio") {
        // "ok": the password (not empty) and, when the sheet asked for one, the name (not empty); the check box when it was
        // offered. "cancel" carries nothing (the bridge cancels a cancellation that carries anything).
        if (ok === true) {
            const login = isObject(request.login) ? request.login : {nameMode: request.nameMode, remember: request.remember};
            if (typeof password !== "string" || password.length === 0 || utf8Length(password) > MAX_PASSWORD_BYTES)
                return "";
            if (login.nameMode === "edit") {
                if (typeof identity !== "string" || identity.length === 0 || utf8Length(identity) > MAX_IDENTITY_BYTES)
                    return "";
                m.identity = identity;
            }
            m.password = password;
            if (login.remember === "off" || login.remember === "on")
                m.choice = choice === true;
        }
        const kioLine = JSON.stringify(m);
        return utf8Length(kioLine) <= MAX_SHELL_LINE ? kioLine : "";
    }
    if (request.kind === "nm") {
        if (ok === true) {
            if (typeof password !== "string" || password.length === 0 || utf8Length(password) > MAX_PASSWORD_BYTES)
                return "";
            m.password = password;
        }
        const nmLine = JSON.stringify(m);
        return utf8Length(nmLine) <= MAX_SHELL_LINE ? nmLine : "";
    }
    if (ok === true && request.kind === "password") {
        if (typeof password !== "string" || (password.length === 0 && request.passwordNew !== true) || utf8Length(password) > MAX_PASSWORD_BYTES)
            return "";
        m.password = password;
    }
    if (request.choice !== null && request.choice !== undefined)
        m.choice = choice === true;
    const line = JSON.stringify(m);
    return utf8Length(line) <= MAX_SHELL_LINE ? line : "";
}

// The shell's refusal of a request it cannot take (its bound of MAX_REQUESTS, no queue): result "refused", never a user's
// "cancel", so that NetworkManager hears NoSecrets, not UserCanceled (opus review of step 9c, NIT; decision 9-31). "" for
// an id the bridge would not have sent.
function refusalLine(id) {
    return validId(id) ? JSON.stringify({type: "answer", id: id, result: "refused"}) : "";
}
