pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import "DisplaysFile.js" as DisplaysFile

// Settings > Displays' link to the compositor (ADR-0027). The shell is the only Grassfield process that talks to Hyprland:
// - it publishes the monitors (Hyprland's own `monitors` answer, through Quickshell), the backlight and the trial's state in
//   a runtime file the Settings app reads (DisplaysFile.js has the format and the paths);
// - it runs a trial: when Settings writes the trial file, it asks Hyprland to read its configuration again (the request
//   `reload` on the request socket; config/hypr/grassfield/displays.lua applies the trial while it runs), and takes it back
//   after its deadline, on Revert, or when it finds a trial at start: the file is emptied, then the configuration read again.
//   Keep empties the file without a reload (Settings wrote displays.conf first). The countdown is the shell's, so a Settings
//   that crashed or was closed cannot leave a display in a mode nobody confirmed.
// In a dev session the files are under GRASSFIELD_STATE_HOME and the request socket is the nested Hyprland's.
Singleton {
    id: root

    // The backlight ({device, level}) or null; shell.qml binds Brightness into it (ADR-0021: platform imports lib only).
    property var backlight: null

    readonly property string statePath: DisplaysFile.statePath(Mode.dev, Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))
    readonly property string trialPath: DisplaysFile.trialPath(Mode.dev, Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))

    // The trial being run ("" for none) and its last outcome, as published.
    property string running: ""
    property var trialState: null
    // The first look at the trial file since the shell started (a trial found then is taken back).
    property bool starting: true
    property int reloads: 0

    function publish(): void {
        if (root.statePath === "")
            return;
        if (stateFile.path !== root.statePath)
            stateFile.path = root.statePath;
        const monitors = (Hyprland.monitors ? Hyprland.monitors.values : []).map(m => m.lastIpcObject);
        stateFile.setText(DisplaysFile.payload(monitors, root.backlight, root.trialState));
    }

    onBacklightChanged: publishDebounce.restart()

    // Hyprland reads its configuration again (the trial applied or taken back): one connection per request, as the blur push.
    function reload(): void {
        const path = Hyprland.requestSocketPath || "";
        if (path === "") {
            console.info("grassfield-shell: displays: no Hyprland request socket, the configuration is not read again");
            return;
        }
        root.reloads++;
        reloadSocket.createObject(root, {"path": path});
    }

    function empty(): void {
        trialFile.setText("");
    }

    function handle(text: string): void {
        const trial = DisplaysFile.parseTrial(text);
        const what = DisplaysFile.action(trial, root.running, root.starting, Math.floor(Date.now() / 1000));
        root.starting = false;
        if (what === "apply") {
            root.running = trial.id;
            root.trialState = {id: trial.id, state: "applied"};
            deadline.interval = Math.max(0, trial.until * 1000 - Date.now());
            deadline.restart();
            console.info("grassfield-shell: displays: trial " + trial.id + " applied");
            root.reload();
        } else if (what === "keep") {
            deadline.stop();
            root.trialState = {id: root.running, state: "kept"};
            console.info("grassfield-shell: displays: trial " + root.running + " kept");
            root.running = "";
            root.empty();
        } else if (what === "revert") {
            root.revert(trial ? trial.id : root.running);
        }
        publishDebounce.restart();
    }

    function revert(id: string): void {
        deadline.stop();
        root.trialState = id !== "" ? {id: id, state: "reverted"} : null;
        console.info("grassfield-shell: displays: trial " + (id !== "" ? id : "(none)") + " taken back");
        root.running = "";
        root.empty();
        root.reload();
        publishDebounce.restart();
    }

    Timer {
        id: deadline
        onTriggered: root.revert(root.running)
    }

    // The monitors change in bursts (a reload, a hot-plug): one write per settle.
    Timer {
        id: publishDebounce
        interval: Tokens.motionFast
        onTriggered: root.publish()
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "monitoradded" || event.name === "monitoraddedv2" || event.name === "monitorremoved"
                || event.name === "monitorremovedv2" || event.name === "configreloaded") {
                Hyprland.refreshMonitors();
                publishDebounce.restart();
            }
        }
    }

    FileView {
        id: stateFile
        printErrors: false
        atomicWrites: true
    }

    FileView {
        id: trialFile
        path: root.trialPath
        printErrors: false
        watchChanges: true
        atomicWrites: true
        onFileChanged: reload()
        onLoaded: root.handle(trialFile.text())
        onLoadFailed: root.handle("")
    }

    // One connection per request: it sends `reload` and collects the answer until Hyprland closes the connection (or the
    // answer is late), then it is judged once and destroyed later (a Socket cannot be destroyed from its own error signal).
    Component {
        id: reloadSocket

        Socket {
            id: sock
            property string reply: ""
            property bool judged: false

            function finish(): void {
                if (sock.judged)
                    return;
                sock.judged = true;
                sock.answerTimeout.stop();
                if (sock.reply.trim() !== "ok")
                    console.info("grassfield-shell: displays: Hyprland answered the reload with \"" + sock.reply.trim() + "\"");
                sock.connected = false;
                Qt.callLater(() => sock.destroy());
            }

            parser: SplitParser {
                // No separator: Hyprland's answer has no newline, take what arrives and add it up.
                splitMarker: ""
                onRead: data => sock.reply += data
            }
            onConnectedChanged: {
                if (connected) {
                    write("reload");
                    flush();
                    sock.answerTimeout.start();
                } else {
                    sock.finish();
                }
            }

            readonly property Timer answerTimeout: Timer {
                interval: Tokens.materialBlurAnswerMs
                onTriggered: sock.finish()
            }

            Component.onCompleted: {
                sock.error.connect(() => sock.finish());
                sock.connected = true;
            }
        }
    }

    Component.onCompleted: {
        Hyprland.refreshMonitors();
        publishDebounce.restart();
    }
}
