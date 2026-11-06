import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import "DisplayArrival.js" as Arrival

// A combination of displays never seen before (ADR-0044 amendment A-1): once the connected displays have settled
// (Arrival.SETTLE_MS without a change) into a set of two or more this user never had, `offered` fires once, and shell.qml
// posts the notice whose click opens Settings > Displays. The combination the session starts with and a single display are
// recorded silently; a combination already seen, or one the user chose a main display for (`displays.main`), gives nothing;
// while the screen is locked the offer waits for the unlock. Not in a dev shell on the owner's displays (Arrival.allowed).
// The seen-set is `displays-seen.json` in the shell's state folder (0600, folder 0700), written only where offering is allowed.
Item {
    id: root

    // A new combination to offer (its key; the caller posts the notice).
    signal offered(string key)

    visible: false

    readonly property bool allowed: Arrival.allowed(Mode.session, Mode.dev, Mode.stateHome !== "", MainDisplay.names)
    readonly property string seenPath: Mode.stateDir + "/displays-seen.json"
    // The connected combination, once Hyprland has described every output ("" before).
    readonly property string key: MainDisplay.live.ready ? Arrival.comboKey(DisplayRole.setOf(MainDisplay.live.displays)) : ""

    property var seen: []
    // The seen-set was read (or found missing): nothing is decided before.
    property bool loaded: false
    // The first settled combination of this run has been handled (it is the one the session started with).
    property bool startupDone: false
    property var tracker: Arrival.track(null, "", 0)

    onKeyChanged: {
        root.tracker = Arrival.track(root.tracker, root.key, Date.now());
        settle.restart();
    }

    onAllowedChanged: {
        if (root.allowed && !prepare.running && seenFile.path === "")
            prepare.running = true;
    }

    Component.onCompleted: {
        root.tracker = Arrival.track(root.tracker, root.key, Date.now());
        if (root.allowed)
            prepare.running = true;
        settle.restart();
    }

    function evaluate(): void {
        if (!root.loaded || !root.allowed)
            return;
        const now = Date.now();
        if (!Arrival.settled(root.tracker, now)) {
            if (root.key !== "")
                settle.restart();
            return;
        }
        const startup = !root.startupDone;
        root.startupDone = true;
        const action = Arrival.decide({
            key: root.key,
            startup: startup,
            known: Arrival.isKnown(root.seen, root.key, Settings.displaysMain),
            allowed: root.allowed,
            locked: SessionState.locked
        });
        if (action === "remember" || action === "offer") {
            root.seen = Arrival.remember(root.seen, root.key);
            seenFile.setText(Arrival.serializeSeen(root.seen));
        }
        if (action === "offer") {
            console.info("grassfield-shell: displays: a combination not seen before,", Arrival.countOf(root.key), "displays: offering Displays Settings");
            root.offered(root.key);
        }
    }

    Timer {
        id: settle
        interval: Arrival.SETTLE_MS
        onTriggered: root.evaluate()
    }

    // A new combination that arrived while locked is offered after the unlock (if it is still connected).
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (!SessionState.locked)
                root.evaluate();
        }
    }

    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", Mode.stateDir, root.seenPath]
        onRunningChanged: {
            if (!running)
                seenFile.path = root.seenPath;
        }
    }

    FileView {
        id: seenFile
        printErrors: false
        atomicWrites: true
        onLoaded: {
            root.seen = Arrival.parseSeen(seenFile.text());
            root.loaded = true;
            root.evaluate();
        }
        onLoadFailed: {
            root.seen = [];
            root.loaded = true;
            root.evaluate();
        }
    }
}
