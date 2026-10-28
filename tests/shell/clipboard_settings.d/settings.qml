pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import "services/ClipboardLogic.js" as Logic

// tests/shell/clipboard_settings.sh: what the REAL Clipboard and Settings services ask of the helper (ADR-0034 §6; reviews of
// f7cd664, c1fc254 and 3f924d9), read from the log of tests/shell/clipboard_settings.d/fake-helper. Prints "clipboard-settings: PASS" or
// the failures. grassfield.json does not exist at start.
// - No usable file (missing, too large, malformed, unsafe, empty, whitespace only): nothing runs and nothing is deleted.
// - The first usable read with the history off: --clear-history, then --apply-clears with the settings' times, one after the
//   other; a clear asked while off runs --apply-clears with its time.
// - The history on: the helper is given the settings (the clears' times included); Clear sends CH <ms>, Clear with the pins
//   CH <ms> and CP <ms>; the duration sends T, Keep off D 0, the history off D 0 then QUIT.
// - The file unusable while the history runs (unsafe, malformed, too large, missing, empty): nothing is sent; usable again with the
//   same values: nothing is sent either.
ShellRoot {
    id: root

    readonly property string file: Settings.configDir + "/grassfield.json"
    readonly property string storeArg: "--state " + Clipboard.storeDir
    property var failures: []
    property int step: -1
    // The log lines before the current step acted, its start and when its condition held.
    property int mark: 0
    property real started: 0
    property real held: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    FileView {
        id: logView
        path: Quickshell.env("CLIPBOARD_FAKE_LOG")
        printErrors: false
    }

    function log(): var {
        logView.reload();
        logView.waitForJob();
        return logView.text().split("\n").filter(l => l !== "");
    }

    // The fake helper's lines since the step acted.
    function lines(): var {
        return root.log().slice(root.mark);
    }

    function has(prefix: string): bool {
        return root.lines().some(l => l.startsWith(prefix));
    }

    function same(name: string, want: var): void {
        const got = root.lines();
        root.check(name + " (got " + JSON.stringify(got) + ")", JSON.stringify(got) === JSON.stringify(want));
    }

    Process {
        id: write
    }

    function put(text: string): void {
        write.command = ["sh", "-c", 'printf "%s" "$2" > "$1.tmp" && mv "$1.tmp" "$1"', "sh", root.file, text];
        write.running = true;
    }

    function shell(script: string): void {
        write.command = ["sh", "-c", script, "sh", root.file];
        write.running = true;
    }

    function doc(clipboard: var): string {
        return JSON.stringify({version: 1, search: {clipboard: clipboard}});
    }

    readonly property string malformed: '{"version":1,"search":{"clipboard":{"enabled":true,"keepOnDisk":true}'
    // Valid JSON with a duplicate key: the shell reads every key's default (history off, no clear), as the Settings app does.
    readonly property string unsafe: '{"version":1,"search":{"clipboard":{"enabled":true}},"search":{"clipboard":{"enabled":true}}}'
    readonly property var kept: ({enabled: true, retention: "7d", keepOnDisk: true, clearedAt: 5000, pinnedClearedAt: 5000})

    function nothingRan(name: string): void {
        root.check(name + ": nothing ran (" + JSON.stringify(root.log()) + ")", root.log().length === 0);
        root.check(name + ": nothing decided", !Clipboard.initialized && Clipboard.state === "off" && !Clipboard.enabled);
    }

    function nothingSent(name: string): void {
        root.same(name + ": nothing sent", []);
        root.check(name + ": the helper runs on the last usable values", Clipboard.helper.running && Clipboard.enabled && Clipboard.keepOnDisk
            && Clipboard.retention === Logic.retentionMs("7d") && Clipboard.clearedAt === 5000 && Clipboard.pinnedClearedAt === 5000);
    }

    // Each step acts, waits until its condition holds (at most 8 s: the store also polls every 10 s, the watch is faster), lets
    // `settle` ms pass for what must NOT happen, then checks.
    function steps(): var {
        return [{
                name: "no file at start",
                act: () => {},
                settle: 1500,
                check: () => root.nothingRan("no file")
            }, {
                name: "too large",
                act: () => root.shell('rm -f "$1" && truncate -s 2M "$1"'),
                until: () => Settings.loaded && Settings.writeBlocked,
                settle: 800,
                check: () => root.nothingRan("too large at start")
            }, {
                name: "missing again",
                act: () => root.shell('rm -f "$1"'),
                until: () => !Settings.writeBlocked,
                check: () => root.nothingRan("missing at start")
            }, {
                name: "malformed",
                act: () => root.put(root.malformed),
                until: () => Settings.writeBlocked,
                settle: 800,
                check: () => root.nothingRan("malformed at start")
            }, {
                name: "missing once more",
                act: () => root.shell('rm -f "$1"'),
                until: () => !Settings.writeBlocked
            }, {
                name: "unsafe",
                act: () => root.put(root.unsafe),
                until: () => Settings.writeBlocked,
                settle: 800,
                check: () => root.nothingRan("unsafe at start")
            }, {
                name: "empty",
                act: () => root.put(""),
                until: () => Settings.validRead && Settings.emptyFile,
                settle: 800,
                check: () => root.nothingRan("empty at start")
            }, {
                name: "missing, then whitespace only",
                act: () => root.shell('rm -f "$1"'),
                until: () => !Settings.validRead && !Settings.writeBlocked
            }, {
                name: "whitespace only",
                act: () => root.put(" \n\t\n"),
                until: () => Settings.validRead && Settings.emptyFile,
                settle: 800,
                check: () => root.nothingRan("whitespace only at start")
            }, {
                name: "usable, history off",
                act: () => root.put(root.doc({enabled: false, clearedAt: 1000, pinnedClearedAt: 2000})),
                until: () => root.has("END --apply-clears"),
                settle: 300,
                check: () => {
                    root.check("the first usable read decides", Clipboard.initialized && !Clipboard.enabled && Clipboard.state === "off");
                    root.same("history off: the history store deleted, then the clears carried out, one after the other", [
                        "RUN --clear-history " + root.storeArg, "END --clear-history",
                        "RUN --apply-clears " + root.storeArg + " --cleared-at 1000 --pinned-cleared-at 2000", "END --apply-clears"]);
                }
            }, {
                name: "a clear while off",
                act: () => root.put(root.doc({enabled: false, clearedAt: 3000, pinnedClearedAt: 2000})),
                until: () => root.has("END --apply-clears"),
                settle: 300,
                check: () => root.same("a clear while off: --apply-clears with its time", [
                    "RUN --apply-clears " + root.storeArg + " --cleared-at 3000 --pinned-cleared-at 2000", "END --apply-clears"])
            }, {
                name: "history on",
                act: () => root.put(root.doc({enabled: true, retention: "7d", keepOnDisk: true, clearedAt: 3000, pinnedClearedAt: 2000})),
                until: () => Clipboard.state === "ok" && root.has("IN R"),
                settle: 300,
                check: () => root.same("history on: the helper is given the settings and the clears' times", [
                    "RUN --display " + Clipboard.display + " " + root.storeArg + " --runtime " + Clipboard.runtimeDir + " --retention "
                    + Logic.retentionMs("7d") + " --history-store 1 --cleared-at 3000 --pinned-cleared-at 2000", "IN R"])
            }, {
                name: "Clear",
                act: () => root.put(root.doc({enabled: true, retention: "7d", keepOnDisk: true, clearedAt: 4000, pinnedClearedAt: 2000})),
                until: () => root.has("IN CH"),
                settle: 300,
                check: () => root.same("Clear: CH with its time", ["IN CH 4000"])
            }, {
                name: "Clear with the pins",
                act: () => root.put(root.doc(root.kept)),
                until: () => root.has("IN CP"),
                settle: 300,
                check: () => root.same("Clear with the pins: CH and CP with their time", ["IN CH 5000", "IN CP 5000"])
            }, {
                name: "unsafe while on",
                act: () => root.put(root.unsafe),
                until: () => !Settings.validRead,
                settle: 1000,
                check: () => root.nothingSent("unsafe while on")
            }, {
                name: "usable again",
                act: () => root.put(root.doc(root.kept)),
                until: () => Settings.validRead,
                settle: 600,
                check: () => root.nothingSent("usable again after unsafe")
            }, {
                name: "malformed while on",
                act: () => root.put(root.malformed),
                until: () => !Settings.validRead,
                settle: 1000,
                check: () => root.nothingSent("malformed while on")
            }, {
                name: "usable again",
                act: () => root.put(root.doc(root.kept)),
                until: () => Settings.validRead,
                settle: 600,
                check: () => root.nothingSent("usable again after malformed")
            }, {
                name: "too large while on",
                act: () => root.shell('rm -f "$1" && truncate -s 2M "$1"'),
                until: () => !Settings.validRead && Settings.writeBlocked,
                settle: 1000,
                check: () => root.nothingSent("too large while on")
            }, {
                name: "usable again",
                act: () => root.put(root.doc(root.kept)),
                until: () => Settings.validRead,
                settle: 600,
                check: () => root.nothingSent("usable again after too large")
            }, {
                name: "missing while on",
                act: () => root.shell('rm -f "$1"'),
                until: () => !Settings.validRead && !Settings.writeBlocked,
                settle: 1000,
                check: () => root.nothingSent("missing while on")
            }, {
                name: "usable again",
                act: () => root.put(root.doc(root.kept)),
                until: () => Settings.validRead,
                settle: 600,
                check: () => root.nothingSent("usable again after missing")
            }, {
                name: "empty while on",
                act: () => root.put(""),
                until: () => Settings.validRead && Settings.emptyFile,
                settle: 1000,
                check: () => root.nothingSent("empty while on")
            }, {
                name: "usable again",
                act: () => root.put(root.doc(root.kept)),
                until: () => Settings.validRead && !Settings.emptyFile,
                settle: 600,
                check: () => root.nothingSent("usable again after empty")
            }, {
                name: "duration",
                act: () => root.put(root.doc(Object.assign({}, root.kept, {retention: "30m"}))),
                until: () => root.has("IN T"),
                settle: 300,
                check: () => root.same("the duration: T", ["IN T " + Logic.retentionMs("30m")])
            }, {
                name: "Keep off",
                act: () => root.put(root.doc(Object.assign({}, root.kept, {retention: "30m", keepOnDisk: false}))),
                until: () => root.has("IN D"),
                settle: 300,
                check: () => root.same("Keep off: D 0", ["IN D 0"])
            }, {
                name: "history off",
                act: () => root.put(root.doc(Object.assign({}, root.kept, {enabled: false, retention: "30m", keepOnDisk: false}))),
                until: () => root.has("END helper"),
                settle: 600,
                check: () => {
                    root.same("history off: the helper deletes its history store and ends; no store job beside it", ["IN D 0", "IN QUIT", "END helper"]);
                    root.check("history off: the service is off", Clipboard.state === "off" && !Clipboard.helper.running);
                }
            }];
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("clipboard-settings: PASS");
            Qt.exit(0);
        } else {
            console.log("clipboard-settings: FAIL " + failures.join(" | "));
            Qt.exit(1);
        }
    }

    property var script: []

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            if (root.script.length === 0)
                root.script = root.steps();
            const now = Date.now();
            if (root.step >= 0) {
                const s = root.script[root.step];
                if (write.running)
                    return;
                if (root.held === 0) {
                    if (s.until && !s.until()) {
                        if (now - root.started > 8000) {
                            root.check(s.name + ": timed out (" + JSON.stringify(root.lines()) + ")", false);
                            root.finish();
                            running = false;
                        }
                        return;
                    }
                    root.held = now;
                }
                if (now - root.held < (s.settle || 0))
                    return;
                if (s.check)
                    s.check();
            }
            if (++root.step >= root.script.length) {
                running = false;
                root.finish();
                return;
            }
            root.mark = root.log().length;
            root.started = now;
            root.held = 0;
            root.script[root.step].act();
        }
    }
}
