pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import "DisplaysFile.js" as DisplaysFile

// Settings > Displays' link to the compositor (ADR-0031). The shell is the only Grassfield process that talks to Hyprland:
// - it publishes the monitors (Hyprland's own `monitors` answer, through Quickshell), the backlight and the trial's state in
//   a runtime file the Settings app reads (DisplaysFile.js has the format and the paths);
// - it runs a trial: when Settings writes the trial file, it asks Hyprland to read its configuration again (the request
//   `reload` through SessionConfig; config/hypr/grassfield/displays.lua applies the trial while it runs), publishes it
//   `applying`, then `applied` once Hyprland answers that very request (it has read the configuration: Settings takes Keep
//   only then), and takes it back after its deadline, on Revert, or when it finds a trial at start: the file is emptied, then
//   the configuration read again.
//   Keep empties the file without a reload and publishes `kept`; Settings then writes displays.conf (a Keep the shell did not
//   take, after its deadline, writes nothing). The countdown is the shell's, so a Settings
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
    // The ticket of the reload that applies the trial being run (SessionConfig.answered; 0 for none).
    property int applying: 0
    // The monitors (IPC objects) last published with a name.
    property var described: []
    // The last text written (and the path it went to).
    property string written: ""

    function publish(): void {
        if (root.statePath === "")
            return;
        if (stateFile.path !== root.statePath)
            stateFile.path = root.statePath;
        const objects = Hyprland.monitors ? Hyprland.monitors.values : [];
        let monitors = objects.map(m => m.lastIpcObject).filter(o => o && o.name);
        // A refresh in flight leaves the objects without their answer: never publish none over the monitors already described.
        // None is published only when Hyprland has no monitor at all, or before any was ever described.
        if (monitors.length === 0 && objects.length > 0 && root.described.length > 0)
            monitors = root.described;
        root.described = monitors;
        const text = DisplaysFile.payload(monitors, root.backlight, root.trialState);
        // Quickshell reports every `monitors` answer as a change, changed or not (the lock asks every second): write only news.
        if (DisplaysFile.same(root.written, text))
            return;
        root.written = text;
        stateFile.setText(text);
    }

    onBacklightChanged: publishDebounce.restart()

    // Hyprland reads its configuration again (the trial applied or taken back): SessionConfig's one request.
    function reload(): int {
        root.reloads++;
        return SessionConfig.reload("display trial", Tokens.settingsDisplayTrialAnswerMs);
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
            root.trialState = {id: trial.id, state: "applying"};
            deadline.interval = DisplaysFile.countdownMs(trial.until, Date.now());
            deadline.restart();
            console.info("grassfield-shell: displays: trial " + trial.id + " applying");
            root.applying = root.reload();
        } else if (what === "keep") {
            deadline.stop();
            root.applying = 0;
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
        root.applying = 0;
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

    // Hyprland's answer to `monitors` arrives after the shell started (and after every refresh): each monitor object gets its
    // lastIpcObject then, so a change of it, a monitor added or one removed publishes (debounced).
    Instantiator {
        model: Hyprland.monitors
        onObjectAdded: publishDebounce.restart()
        onObjectRemoved: publishDebounce.restart()

        // The signal only: the value is a whole map converted for every answer, and publish() reads it once per settle.
        delegate: Connections {
            required property HyprlandMonitor modelData

            target: modelData

            function onLastIpcObjectChanged(): void {
                publishDebounce.restart();
            }
        }
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

    Connections {
        target: SessionConfig

        function onAnswered(ticket: int, ok: bool): void {
            const next = DisplaysFile.answered(root.trialState, root.running, root.applying, ticket, ok);
            if (next === root.trialState)
                return;
            root.applying = 0;
            root.trialState = next;
            console.info("grassfield-shell: displays: trial " + root.running + " applied");
            publishDebounce.restart();
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
        // Emptied before the reload is asked for: the write is done when setText returns, so the configuration read again
        // never finds the trial being taken back.
        blockWrites: true
        onFileChanged: reload()
        onLoaded: root.handle(trialFile.text())
        onLoadFailed: root.handle("")
    }

    // No refreshMonitors() here: Quickshell already asks Hyprland for `monitors` when its IPC starts, and a second request
    // while that one is in flight leaves the monitor model empty (Quickshell 0.3.1; found with tests/shell/displays_publish.sh).
    // The Instantiator above publishes when the answer arrives.
    Component.onCompleted: {
        publishDebounce.restart();
    }
}
