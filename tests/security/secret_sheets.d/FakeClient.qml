import QtQuick
import "../../../shell/security/secret/Prompter.js" as Prompter

// PrompterClient for the secret agent's harness (tests/security/secret_sheets.sh): the same properties, signals and
// answer() rule (once per open request, the line Prompter.answerLine builds), no socket. secret_sheets.sh copies it next
// to the Prompter.js under test (its import then names that copy). The tests send requests
// (prompt), withdrawals (withdraw) and a lost connection (drop), and read what the shell answered (`answers`).
QtObject {
    id: fake

    property string path: ""
    property string shellVersion: ""
    property string state: "ready"
    property string nameState: "owned"
    property int openCount: 0
    property var open: ({})
    // Every answer sent: {id, ok, password, choice, identity, line}.
    property var answers: []

    signal prompted(var request)
    signal withdrawn(string id)
    signal lost

    function answer(id: string, ok: bool, password: var, choice: bool, identity: var): bool {
        if (!Object.prototype.hasOwnProperty.call(fake.open, id))
            return false;
        const line = Prompter.answerLine(fake.open[id], ok, password, choice, identity);
        if (line === "")
            return false;
        delete fake.open[id];
        fake.openCount = Object.keys(fake.open).length;
        fake.answers.push({id: id, ok: ok, password: password, choice: choice, identity: identity, line: line});
        return true;
    }

    // The shell's refusal (its bound): "refused", once per open request (Prompter.refusalLine).
    function refuse(id: string): bool {
        if (!Object.prototype.hasOwnProperty.call(fake.open, id))
            return false;
        const line = Prompter.refusalLine(id);
        if (line === "")
            return false;
        delete fake.open[id];
        fake.openCount = Object.keys(fake.open).length;
        fake.answers.push({id: id, ok: false, password: null, choice: false, identity: null, line: line});
        return true;
    }

    // A NetworkManager request (kind nm, step 9c) as the bridge sends it, parsed by the real parser (WPA2 by default).
    function promptNetwork(id: string, network: var): var {
        const m = {type: "prompt", id: id, kind: "nm", network: Object.assign({ssid: "Home", security: "wpa", identity: ""}, network || {})};
        const parsed = Prompter.parseBridgeLine(JSON.stringify(m), true);
        if (!parsed.ok)
            throw new Error(parsed.reason);
        fake.open[id] = parsed.message;
        fake.openCount = Object.keys(fake.open).length;
        fake.prompted(parsed.message);
        return parsed.message;
    }

    // A request as the bridge sends it, parsed by the real parser (keyring by default).
    function prompt(id: string, over: var): var {
        const m = {
            type: "prompt",
            id: id,
            kind: "password",
            requester: {role: "keyring", name: "", desktopId: "", icon: "", path: "/usr/bin/gnome-keyring-daemon", identified: true, onBehalf: true},
            texts: {title: "Authentication required", message: "Unlock the login keyring", description: "", warning: "", "continue": "Allow", cancel: ""},
            choice: null,
            passwordNew: false,
            strength: false
        };
        const parsed = Prompter.parseBridgeLine(JSON.stringify(Object.assign(m, over || {})), true);
        if (!parsed.ok)
            throw new Error(parsed.reason);
        fake.open[id] = parsed.message;
        fake.openCount = Object.keys(fake.open).length;
        fake.prompted(parsed.message);
        return parsed.message;
    }

    function withdraw(id: string): void {
        if (!Object.prototype.hasOwnProperty.call(fake.open, id))
            return;
        delete fake.open[id];
        fake.openCount = Object.keys(fake.open).length;
        fake.withdrawn(id);
    }

    function drop(): void {
        fake.open = {};
        fake.openCount = 0;
        fake.lost();
    }
}
