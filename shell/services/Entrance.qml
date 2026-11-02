pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui
import "EntranceLogic.js" as Logic

// The session's entrance (ADR-0040 step 6, ID-20, ID-5, P-3): the wallpaper first, out of the ground (it maps with its own
// first frame, step 3); then the menu bar, the Dock and the desktop icons together, in one fade of session.revealMs, once
// every one of them has its final content. Each surface says it is expected when it is created (`expect`) and final when it
// is (`ready`); `revealed` latches once all are, or after session.revealTimeoutMs, whichever comes first, and never goes
// back: a surface created later (a hotplugged output) is simply shown. The settings come first (ID-5): `settingsFinal` once
// they are read, or session.settingsWaitMs after the start (the defaults then). begin() is called as the desktop is created
// (the clocks start there). The bound never lets the bars come before the wallpaper: on it, the entrance still waits for any
// wallpaper's first frame, which has its own bound (wallpaper.firstShowTimeoutMs). Journal: `grassfield-shell: entrance
// (<why>; waited for <keys>)`.
Singleton {
    id: root

    property var expected: ({})
    property bool revealed: false
    // The bound ran out while a wallpaper still drew its first frame: the entrance follows that frame (review of 3a5e1b80).
    property bool timedOut: false
    property bool settingsWaited: false
    readonly property bool settingsFinal: Settings.loaded || root.settingsWaited

    function begin(): void {
        if (!revealTimer.running && !root.revealed) {
            revealTimer.start();
            hardTimer.start();
        }
        if (!settingsTimer.running && !root.settingsWaited)
            settingsTimer.start();
    }

    function expect(key: string): void {
        if (root.revealed)
            return;
        root.expected = Logic.withExpected(root.expected, key);
    }

    function ready(key: string): void {
        if (root.revealed)
            return;
        root.expected = Logic.withReady(root.expected, key);
        // After the current event: surfaces created in the same pass have said they are expected by then.
        Qt.callLater(root.check);
    }

    // A surface that goes before the entrance (its output was removed) is no longer waited for.
    function forget(key: string): void {
        if (root.revealed)
            return;
        root.expected = Logic.without(root.expected, key);
        Qt.callLater(root.check);
    }

    function check(): void {
        if (root.revealed)
            return;
        if (Logic.allReady(root.expected))
            root.reveal("ready");
        else if (root.timedOut && !Logic.wallpaperPending(root.expected))
            root.reveal("timeout");
    }

    function reveal(why: string): void {
        if (root.revealed)
            return;
        const waited = Logic.pending(root.expected);
        root.revealed = true;
        revealTimer.stop();
        hardTimer.stop();
        console.info("grassfield-shell: entrance (" + why + (waited.length > 0 ? "; waited for " + waited.join(" ") : "") + ")");
    }

    Timer {
        id: revealTimer
        interval: Tokens.sessionRevealTimeoutMs
        onTriggered: {
            root.timedOut = true;
            root.check();
        }
    }

    // The hard bound, whatever is pending (a key that leaked, a surface that never answers): the wallpaper's own bound past
    // the entrance's.
    Timer {
        id: hardTimer
        interval: Tokens.sessionRevealTimeoutMs + Tokens.wallpaperFirstShowTimeoutMs
        onTriggered: root.reveal("timeout")
    }

    Timer {
        id: settingsTimer
        interval: Tokens.sessionSettingsWaitMs
        onTriggered: {
            if (!Settings.loaded)
                console.warn("grassfield-shell: the settings were not read within " + interval + " ms; the entrance uses the defaults");
            root.settingsWaited = true;
        }
    }
}
