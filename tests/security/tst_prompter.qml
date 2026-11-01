import QtQuick
import QtTest
import "../../shell/security/secret/Prompter.js" as Prompter

// prompter/1, the shell's side (shell/security/secret/Prompter.js; ADR-0035 D-9, step 9b): the bridge's lines read strictly
// (anything else closes the connection), the flattening rule of the bridge (decision 9-13), the answer lines, the socket
// path's run-mode rule and the back-off; step 9c: NetworkManager's kind (nm), its length rule and answers, the disk role.
TestCase {
    name: "Prompter"

    function prompt(over) {
        const m = {
            type: "prompt",
            id: "p1",
            kind: "password",
            requester: {role: "keyring", name: "", desktopId: "", icon: "", path: "/usr/bin/gnome-keyring-daemon", identified: true, onBehalf: true},
            texts: {title: "Unlock Keyring", message: "Authentication required", description: "An app wants access", warning: "", "continue": "Unlock", cancel: ""},
            choice: {label: "Unlock automatically", chosen: false},
            passwordNew: false,
            strength: false
        };
        return Object.assign(m, over || {});
    }

    function line(o) {
        return JSON.stringify(o);
    }

    function parse(o, helloSeen) {
        return Prompter.parseBridgeLine(typeof o === "string" ? o : line(o), helloSeen === undefined ? true : helloSeen);
    }

    function test_hello() {
        const ok = parse({v: "prompter/1", type: "hello", bridge: "0.9", kinds: ["password", "confirm"], max: 8}, false);
        verify(ok.ok, ok.reason);
        compare(ok.message.type, "hello");
        verify(!parse({v: "prompter/2", type: "hello", bridge: "1", kinds: [], max: 8}, false).ok, "another version closes");
        verify(!parse({v: "prompter/1", type: "hello", bridge: "1", kinds: [], max: 8, extra: 1}, false).ok, "an unknown key");
        verify(!parse({v: "prompter/1", type: "hello", bridge: "1", kinds: [], max: "8"}, false).ok, "max is a number");
        verify(!parse({v: "prompter/1", type: "hello", bridge: "0.9", kinds: ["password"], max: 8}, true).ok, "a second hello");
    }

    function test_beforeHello() {
        verify(!parse({type: "name", state: "owned"}, false).ok, "nothing before hello");
        verify(!parse(prompt(), false).ok, "no prompt before hello");
        const refusal = parse({type: "error", code: "refused", message: "not the shell"}, false);
        verify(refusal.ok, "the bridge's refusal comes instead of its hello");
        compare(refusal.message.code, "refused");
    }

    function test_malformed_data() {
        return [
            {tag: "not JSON", l: "{\"type\":"},
            {tag: "an array", l: "[1,2]"},
            {tag: "a string", l: "\"prompt\""},
            {tag: "no type", l: "{\"id\":\"p1\"}"},
            {tag: "unknown type", l: "{\"type\":\"pwn\"}"},
            {tag: "too long", l: "{\"type\":\"name\",\"state\":\"owned\",\"x\":\"" + "a".repeat(Prompter.MAX_BRIDGE_LINE) + "\"}"},
            {tag: "name: unknown state", l: line({type: "name", state: "mine"})},
            {tag: "cancel: bad id", l: line({type: "cancel", id: "p01"})},
            {tag: "cancel: extra key", l: line({type: "cancel", id: "p1", password: "x"})}
        ];
    }
    function test_malformed(d) {
        verify(!Prompter.parseBridgeLine(d.l, true).ok, d.tag);
    }

    function test_prompt() {
        const r = parse(prompt());
        verify(r.ok, r.reason);
        const m = r.message;
        compare(m.id, "p1");
        compare(m.kind, "password");
        compare(m.requester.role, "keyring");
        compare(m.requester.onBehalf, true);
        compare(m.texts.title, "Unlock Keyring");
        compare(m.texts.continueLabel, "Unlock");
        compare(m.choice.label, "Unlock automatically");
        compare(m.choice.chosen, false);
        verify(parse(prompt({choice: null})).ok, "no check box");
        verify(parse(prompt({kind: "confirm"})).ok, "a confirmation");
        verify(parse(prompt({passwordNew: true, strength: true})).ok, "a new password");
    }

    // Every way a prompt can be wrong closes the connection: the shell never draws what the bridge would not send.
    function test_promptRefused_data() {
        const base = prompt();
        const req = o => Object.assign({}, base.requester, o);
        const txt = o => Object.assign({}, base.texts, o);
        return [
            {tag: "unknown kind", p: prompt({kind: "kio"})},
            {tag: "nm with a gcr prompt's keys", p: prompt({kind: "nm"})},
            {tag: "disk not on behalf", p: prompt({requester: req({role: "disk", onBehalf: false})})},
            {tag: "bad id", p: prompt({id: "x1"})},
            {tag: "id with a leading zero", p: prompt({id: "p0"})},
            {tag: "extra key", p: Object.assign(prompt(), {password: "x"})},
            {tag: "missing key", p: (() => { const p = prompt(); delete p.strength; return p; })()},
            {tag: "requester extra key", p: prompt({requester: req({pid: 1})})},
            {tag: "unknown role", p: prompt({requester: req({role: "root"})})},
            {tag: "keyring not on behalf", p: prompt({requester: req({onBehalf: false})})},
            {tag: "unidentified but identified", p: prompt({requester: req({role: "unidentified", identified: true, onBehalf: false})})},
            {tag: "app without a name", p: prompt({requester: req({role: "app", name: "", onBehalf: false})})},
            {tag: "keyring with a name", p: prompt({requester: req({name: "Authentication required"})})},
            {tag: "identified is a string", p: prompt({requester: req({identified: "true"})})},
            {tag: "title over its cap", p: prompt({texts: txt({title: "t".repeat(129)})})},
            {tag: "description over its cap", p: prompt({texts: txt({description: "d".repeat(1025)})})},
            {tag: "texts extra key", p: prompt({texts: txt({html: "<b>x</b>"})})},
            {tag: "texts number", p: prompt({texts: txt({message: 3})})},
            {tag: "choice without a label", p: prompt({choice: {label: "", chosen: true}})},
            {tag: "choice extra key", p: prompt({choice: {label: "x", chosen: true, y: 1}})},
            {tag: "strength without passwordNew", p: prompt({strength: true})},
            {tag: "passwordNew on a confirmation", p: prompt({kind: "confirm", passwordNew: true, strength: true})},
            {tag: "requester is null", p: prompt({requester: null})}
        ];
    }
    function test_promptRefused(d) {
        verify(!parse(d.p).ok, d.tag);
    }

    // The bridge's rule (decision 9-13, bridges/prompter/src/Text.cpp).
    function test_flatten_data() {
        return [
            {tag: "plain", t: "Unlock", cap: 128, want: "Unlock"},
            {tag: "controls and newlines", t: "a\nb\tc\r\u0085d", cap: 128, want: "a b c d"},
            {tag: "line separators", t: "a\u2028b\u2029c", cap: 128, want: "a b c"},
            {tag: "runs of space trimmed", t: "  a   \u00a0 b  ", cap: 128, want: "a b"},
            {tag: "bidi and zero width removed", t: "a\u202eb\u200bc\u2066d\u2069\u061c\ufeffe", cap: 128, want: "abcde"},
            {tag: "tags and noncharacters removed", t: "a\udb40\udc41b\ufdd0c\uffffd", cap: 128, want: "abcd"},
            {tag: "unpaired surrogate", t: "a\ud800b", cap: 128, want: "a\ufffdb"},
            {tag: "cut with an ellipsis", t: "abcdef", cap: 4, want: "abc\u2026"},
            {tag: "cut never splits a pair", t: "ab\ud83d\ude00cd", cap: 4, want: "ab\u2026"},
            {tag: "no space before the ellipsis", t: "ab cdef", cap: 4, want: "ab\u2026"},
            {tag: "not a string", t: 42, cap: 8, want: ""}
        ];
    }
    function test_flatten(d) {
        compare(Prompter.flatten(d.t, d.cap), d.want);
        compare(Prompter.flatten(Prompter.flatten(d.t, d.cap), d.cap), Prompter.flatten(d.t, d.cap), "idempotent");
    }

    function test_promptTextsFlattenedAgain() {
        const r = parse(prompt({texts: {title: "a\u202eb\nc", message: "", description: "", warning: "", "continue": "", cancel: ""}}));
        verify(r.ok, r.reason);
        compare(r.message.texts.title, "ab c", "a broken bridge's text is flattened by the shell too");
    }

    function test_answerLines() {
        const pw = parse(prompt()).message;
        compare(JSON.parse(Prompter.answerLine(pw, true, "s3cret", true)), {type: "answer", id: "p1", result: "ok", password: "s3cret", choice: true});
        compare(JSON.parse(Prompter.answerLine(pw, false, "ignored", false)), {type: "answer", id: "p1", result: "cancel", choice: false}, "a cancellation carries no password");
        compare(Prompter.answerLine(pw, true, "", false), "", "no empty password for an unlock");
        compare(Prompter.answerLine(pw, true, null, false), "", "ok without a password");
        compare(Prompter.answerLine(pw, true, "x".repeat(4097), false), "", "over 4096 bytes");
        compare(Prompter.answerLine(pw, true, "\u00e9".repeat(2049), false), "", "over 4096 bytes of UTF-8");
        verify(Prompter.answerLine(pw, true, "\u00e9".repeat(2048), false) !== "", "4096 bytes of UTF-8");
        const fresh = parse(prompt({passwordNew: true, strength: true, choice: null})).message;
        compare(JSON.parse(Prompter.answerLine(fresh, true, "", false)), {type: "answer", id: "p1", result: "ok", password: ""}, "an empty new password; no choice key without a check box");
        const confirm = parse(prompt({kind: "confirm", choice: null})).message;
        compare(JSON.parse(Prompter.answerLine(confirm, true, "x", false)), {type: "answer", id: "p1", result: "ok"}, "a confirmation carries no password");
        compare(Prompter.answerLine({id: "p1", kind: "kio"}, true, "x", false), "", "an unknown kind");
    }

    function test_hello_line() {
        compare(JSON.parse(Prompter.helloLine("1.0\n")), {v: "prompter/1", type: "hello", shell: "1.0", kinds: ["password", "confirm", "nm"]});
    }

    // --- step 9c: NetworkManager's kind and the disk role --------------------------------------------------------------

    function nm(over, network) {
        return Object.assign({type: "prompt", id: "p7", kind: "nm", network: Object.assign({ssid: "Home", security: "wpa", identity: ""}, network || {})}, over || {});
    }

    function test_networkPrompt() {
        const r = parse(nm());
        verify(r.ok, r.reason);
        const m = r.message;
        compare([m.id, m.kind, m.network.ssid, m.network.security, m.network.identity], ["p7", "nm", "Home", "wpa", ""]);
        compare(m.requester.role, "network", "the shell's own requester row, never from the request");
        compare(m.requester.onBehalf, false);
        compare([m.texts.title, m.texts.message, m.choice, m.passwordNew, m.strength], ["", "", null, false, false], "no caller text, no check box");
        const e = parse(nm({}, {security: "enterprise", identity: "alice\u202e"}));
        verify(e.ok, e.reason);
        compare(e.message.network.identity, "alice", "the identity flattened");
        compare(parse(nm({}, {ssid: "Caf\u00e9\n\u202eevil"})).message.network.ssid, "Caf\u00e9 evil", "the SSID flattened");
        for (const security of ["wpa3", "wep"])
            verify(parse(nm({}, {security: security})).ok, security);
    }

    function test_networkPromptRefused_data() {
        return [
            {tag: "a requester object", p: nm({requester: {role: "network"}})},
            {tag: "texts", p: nm({texts: {title: "Authentication required"}})},
            {tag: "missing network", p: (() => { const p = nm(); delete p.network; return p; })()},
            {tag: "network extra key", p: nm({}, {password: "x"})},
            {tag: "unknown security", p: nm({}, {security: "owe"})},
            {tag: "SSID over its cap", p: nm({}, {ssid: "s".repeat(65)})},
            {tag: "an SSID that shows nothing", p: nm({}, {ssid: "\u202e \n"})},
            {tag: "a name for a WPA2 network", p: nm({}, {identity: "eve"})},
            {tag: "SSID a number", p: nm({}, {ssid: 3})},
            {tag: "bad id", p: nm({id: "p0"})}
        ];
    }
    function test_networkPromptRefused(d) {
        verify(!parse(d.p).ok, d.tag);
    }

    function test_networkLength() {
        verify(!Prompter.networkLengthOk("wpa", 7), "WPA2: under 8");
        verify(Prompter.networkLengthOk("wpa", 8));
        verify(Prompter.networkLengthOk("wpa", 64), "64 hexadecimal digits");
        verify(!Prompter.networkLengthOk("wpa", 65));
        verify(Prompter.networkLengthOk("wpa3", 1));
        verify(Prompter.networkLengthOk("wep", 5));
        verify(Prompter.networkLengthOk("enterprise", 1));
        verify(!Prompter.networkLengthOk("wep", 0), "never empty");
        verify(!Prompter.networkLengthOk("owe", 8), "an unknown security");
    }

    function test_networkAnswerLines() {
        const w = parse(nm()).message;
        const kept = {id: "p7", kind: "nm", passwordNew: false, choice: null, security: "wpa"};
        compare(JSON.parse(Prompter.answerLine(kept, true, "correct horse", false, null)), {type: "answer", id: "p7", result: "ok", password: "correct horse"});
        compare(JSON.parse(Prompter.answerLine(kept, false, "ignored", true, "ignored")), {type: "answer", id: "p7", result: "cancel"}, "a cancellation carries nothing");
        compare(Prompter.answerLine(kept, true, "", false, null), "", "never an empty Wi-Fi password");
        compare(Prompter.answerLine(kept, true, "x".repeat(4097), false, null), "", "over 4096 bytes");
        compare(JSON.parse(Prompter.answerLine(kept, true, "pw", false, "eve")), {type: "answer", id: "p7", result: "ok", password: "pw"}, "no name for a WPA2 network");
        const ent = Object.assign({}, kept, {security: "enterprise"});
        compare(JSON.parse(Prompter.answerLine(ent, true, "pw", false, "bob")), {type: "answer", id: "p7", result: "ok", password: "pw", identity: "bob"});
        compare(Prompter.answerLine(ent, true, "pw", false, ""), "", "an enterprise answer needs a name");
        compare(Prompter.answerLine(ent, true, "pw", false, null), "", "...a string one");
        compare(Prompter.answerLine(ent, true, "pw", false, "n".repeat(1025)), "", "a name over 1024 bytes");
        verify(w.kind === "nm");
    }

    function test_diskRole() {
        const r = parse(prompt({requester: {role: "disk", name: "", desktopId: "", icon: "", path: "/usr/lib/grassfield/grassfield-askpass", identified: true, onBehalf: true}}));
        verify(r.ok, r.reason);
        compare(r.message.requester.role, "disk");
    }

    function test_utf8Length() {
        compare(Prompter.utf8Length("a\u00e9\u20ac\ud83d\ude00"), 1 + 2 + 3 + 4);
        compare(Prompter.utf8Length("\ud800"), 6, "an unpaired surrogate is written as a \\u escape");
    }

    // ADR-0019: a dev session reaches only its test socket; anything else the session's socket, never an override.
    function test_socketPath() {
        compare(Prompter.socketPath(false, "/run/user/1000", "/tmp/evil.sock"), "/run/user/1000/grassfield/prompter.sock");
        compare(Prompter.socketPath(false, "/run/user/1000/", ""), "/run/user/1000/grassfield/prompter.sock");
        compare(Prompter.socketPath(false, "relative", ""), "", "a relative runtime directory");
        compare(Prompter.socketPath(false, undefined, ""), "", "no runtime directory");
        compare(Prompter.socketPath(true, "/run/user/1000", "/tmp/t/p.sock"), "/tmp/t/p.sock");
        compare(Prompter.socketPath(true, "/run/user/1000", ""), "", "a dev session without a test socket connects nowhere");
        compare(Prompter.socketPath("true", "/run/user/1000", "/tmp/t/p.sock"), "/run/user/1000/grassfield/prompter.sock", "only true is dev");
    }

    function test_retryDelay() {
        compare(Prompter.retryDelay(0), 1000);
        compare(Prompter.retryDelay(1), 2000);
        compare(Prompter.retryDelay(4), 16000);
        compare(Prompter.retryDelay(5), 30000);
        compare(Prompter.retryDelay(1000), 30000);
    }
}
