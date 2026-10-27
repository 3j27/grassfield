pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import qs.platform
import "ClipboardLogic.js" as Logic

// The clipboard history (ADR-0034): runs grassfield-clipboard-helper while Settings > Search > Results from Clipboard is on, with
// the display socket it may watch (never one it was not given: in a dev session only GRASSFIELD_CLIPBOARD_DISPLAY), answers each
// copy it announces (recorded only while the history is on, the session unlocked by both lock sources, no authorization request
// open or just ended, no protected password manager in front), pauses it while the session is locked, and passes on the settings
// (retention, the opt-in history store, Clear Clipboard History). It keeps the items' metadata for Search (titles, excerpts,
// thumbnails; never the full text, which stays in the helper). The view is Search's (step 2).
Singleton {
    id: root

    readonly property bool enabled: Settings.clipboardEnabled
    // "off" (history off), "dev-off" (a dev session without GRASSFIELD_CLIPBOARD_DISPLAY), "starting", "ok", "unsupported" (no
    // ext-data-control-v1 or lock notifier: the view says so), "error" (retried with a growing pause)
    property string state: "off"
    // [{id, kind, mimes, size, copiedAt, pinnedAt, pinned, formatted, files, title, excerpt, thumbnail, app}]: pinned first, newest first
    property var items: []
    // The compositor's lock state as the helper reads it (hyprland_lock_notifier_v1): set by any locker, this shell's or another's.
    property bool helperLocked: false
    // Either lock source: what the view and the paste refuse on.
    readonly property bool locked: SessionState.locked || helperLocked
    // The item the clipboard holds through the helper ("" when another app owns it).
    property string ownedId: ""

    signal searched(int seq, var ids)
    signal pinFull(string id)
    signal previewReady(string id, string path, string text)

    // Dev: the helper built by apps/clipboard-helper/build-direct.sh (GRASSFIELD_CLIPBOARD_HELPER names another, for tests); the
    // session: the package's.
    readonly property string tool: Mode.dev ? (Mode.devValue("CLIPBOARD_HELPER") || Quickshell.shellPath("../.dev/build/grassfield-clipboard-helper")) : "/usr/lib/grassfield/grassfield-clipboard-helper"
    readonly property string display: Logic.displayPath(Mode.dev, Mode.devValue("CLIPBOARD_DISPLAY"), Quickshell.env("XDG_RUNTIME_DIR"), Quickshell.env("WAYLAND_DISPLAY"))
    readonly property string runtimeDir: Logic.runtimeDir(Quickshell.env("XDG_RUNTIME_DIR"), display)
    readonly property string storeDir: Mode.stateDir + "/clipboard"
    readonly property bool runnable: display !== "" && runtimeDir !== ""

    // When the last authorization request ended (ms since the epoch): no copy is recorded for 2 s after it.
    property real authorizingEndedAt: 0
    readonly property bool authorizing: SessionState.authorizing
    onAuthorizingChanged: if (!root.authorizing)
        root.authorizingEndedAt = Date.now()

    // Whether the helper should run; `stopping`: turned off, it deletes its history store, then ends by itself (onEnabledChanged).
    property bool wanted: false
    property bool stopping: false
    property int retryMs: 2000
    property bool waiting: false
    property real lastClearedAt: -1
    property real lastPinnedClearedAt: -1

    function send(fields: var): void {
        if (root.helper.running)
            root.helper.write(Logic.line(fields) + "\n");
    }

    function copy(id: string, plainOnly: bool): void {
        root.send(["C", id, plainOnly ? "1" : "0"]);
    }
    function pin(id: string): void {
        root.send(["PIN", id]);
    }
    function unpin(id: string): void {
        root.send(["UNPIN", id]);
    }
    function remove(id: string): void {
        root.send(["X", id]);
    }
    function clearHistory(): void {
        root.send(["CH"]);
    }
    function search(seq: int, query: string): void {
        root.send(["Q", String(seq), query]);
    }
    function preview(id: string): void {
        root.send(["V", id]);
    }
    function dropPreview(id: string): void {
        root.send(["VD", id]);
    }
    function expireNow(): void {
        root.send(["E"]);
    }

    function decide(seq: string): void {
        const yes = Logic.mayRecord({
            enabled: root.enabled,
            locked: SessionState.locked,
            helperLocked: root.helperLocked,
            authorizing: root.authorizing,
            authorizingEndedAt: root.authorizingEndedAt,
            now: Date.now(),
            activeClass: Compositor.focusedAppId
        });
        send(yes ? ["Y", seq, Compositor.focusedAppId] : ["N", seq]);
    }

    function handle(text: string): void {
        const f = Logic.parseLine(text);
        switch (f[0]) {
        case "S":
            root.state = f[1] === "ok" ? "ok" : f[1] === "unsupported" ? "unsupported" : "error";
            if (f[1] === "ok")
                root.retryMs = 2000;
            break;
        case "L":
            root.helperLocked = f[1] === "1";
            break;
        case "O":
            root.decide(f[1]);
            break;
        case "I": {
            const item = Logic.parseItem(f);
            if (item)
                root.items = Logic.upsert(root.items, item);
            break;
        }
        case "X":
            // The clipboard keeps the helper's copy of a deleted item (ownedId stays).
            root.items = Logic.removeId(root.items, f[1]);
            break;
        case "A":
            root.ownedId = f[1] || "";
            break;
        case "R":
            root.searched(Number(f[1]), f.slice(2));
            break;
        case "N":
            if (f[1] === "pin-full")
                root.pinFull(f[2] || "");
            break;
        case "V":
            root.previewReady(f[1] || "", f[2] || "", f[3] || "");
            break;
        }
    }

    function start(): void {
        if (!root.enabled) {
            root.state = "off";
            return;
        }
        if (!root.runnable) {
            root.state = Mode.dev ? "dev-off" : "error";
            if (Mode.dev)
                console.info("grassfield: clipboard history off in development (set GRASSFIELD_CLIPBOARD_DISPLAY to the nested socket)");
            return;
        }
        root.lastClearedAt = Settings.clipboardClearedAt;
        root.lastPinnedClearedAt = Settings.clipboardPinnedClearedAt;
        root.state = "starting";
        root.wanted = true;
    }

    onEnabledChanged: {
        if (root.enabled) {
            root.start();
            return;
        }
        // Off: the unpinned items go (the helper deletes its history store, then ends; memory ends with it). Pins stay on disk.
        root.items = [];
        root.ownedId = "";
        root.state = "off";
        if (root.helper.running) {
            root.stopping = true;
            root.send(["D", "0"]);
            root.send(["QUIT"]);
        } else {
            root.historyClear.running = true;
        }
        root.wanted = false;
    }

    readonly property real retention: Logic.retentionMs(Settings.clipboardRetention)
    onRetentionChanged: root.send(["T", String(root.retention)])
    readonly property bool keepOnDisk: Settings.clipboardKeepOnDisk
    onKeepOnDiskChanged: root.send(["D", root.keepOnDisk ? "1" : "0"])
    readonly property real clearedAt: Settings.clipboardClearedAt
    onClearedAtChanged: {
        if (root.lastClearedAt >= 0 && root.clearedAt !== root.lastClearedAt)
            root.send(["CH"]);
        root.lastClearedAt = root.clearedAt;
    }
    readonly property real pinnedClearedAt: Settings.clipboardPinnedClearedAt
    onPinnedClearedAtChanged: {
        if (root.lastPinnedClearedAt >= 0 && root.pinnedClearedAt !== root.lastPinnedClearedAt) {
            if (root.helper.running)
                root.send(["CP"]);
            else
                root.pinnedClear.running = true;
        }
        root.lastPinnedClearedAt = root.pinnedClearedAt;
    }

    // Capture follows the shell's own lock as well (SessionState.locked covers its "locking" phase).
    readonly property bool sessionLocked: SessionState.locked
    onSessionLockedChanged: root.send([root.sessionLocked ? "P" : "R"])

    readonly property Process helper: Process {
        running: (root.wanted || root.stopping) && !root.waiting
        command: [root.tool, "--display", root.display, "--state", root.storeDir, "--runtime", root.runtimeDir,
            "--retention", String(root.retention), "--history-store", root.keepOnDisk ? "1" : "0"]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root.handle(line)
        }
        onStarted: root.send([SessionState.locked ? "P" : "R"])
        onExited: (code, status) => {
            root.stopping = false;
            root.helperLocked = false;
            root.ownedId = "";
            root.items = [];
            if (!root.wanted || !root.enabled)
                return;
            if (code === 3) {
                root.state = "unsupported";
                root.wanted = false;
                return;
            }
            // Crashed, or lost the compositor: started again after a pause doubling up to 5 minutes.
            root.state = "error";
            console.warn("grassfield: the clipboard helper ended (" + code + "); started again in " + root.retryMs + " ms");
            root.waiting = true;
            root.retry.interval = root.retryMs;
            root.retry.restart();
            root.retryMs = Math.min(root.retryMs * 2, 300000);
        }
    }

    readonly property Timer retry: Timer {
        repeat: false
        onTriggered: root.waiting = false
    }

    // With the history off: the stores the helper would delete if it ran (a turned-off history keeps no unpinned item on disk;
    // Settings' "Also delete pinned items").
    readonly property Process historyClear: Process {
        command: [root.tool, "--clear-history", "--state", root.storeDir]
    }
    readonly property Process pinnedClear: Process {
        command: [root.tool, "--clear-pinned", "--state", root.storeDir]
    }

    Component.onCompleted: {
        if (root.enabled)
            root.start();
        else
            root.historyClear.running = true;
    }

    IpcHandler {
        target: "clipboard"

        // Test hook: the state and the items' metadata (titles and excerpts are what the user copied: dev only).
        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            return JSON.stringify({
                state: root.state,
                locked: root.locked,
                owned: root.ownedId,
                items: root.items
            });
        }
    }
}
