pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.I18n
import "InputSource.js" as Logic

// Keyboard layout (input source) changes from the compositor, for the input source HUD of shell/osd (macOS shows the
// input source name when it changes). Event-driven (`activelayout`), never polls. Only a CHANGE of a layout the keyboard
// already had is announced (Logic.step): a session with one layout never shows anything. The name is shown in the shell's
// language: Hyprland names a layout by its English xkb description, layout-names.py reads xkeyboard-config's own translation
// of it (a helper process, once per name and language; the English name when there is none).
QtObject {
    id: root

    // The layout name now, as the compositor names it ("" until the first event).
    property string layoutName: ""
    property var memory: ({last: {}})

    // The layout changed to `name` (the HUD shows it), in the shell's language.
    signal layoutChanged(string name)

    // "<language>|<English name>" -> the translated name (a name the helper could not translate maps to itself).
    property var translated: ({})
    // The name the HUD is waiting for, when the helper is busy with an earlier one.
    property string wanted: ""
    property string asking: ""
    property string askingLanguage: ""
    // The longest the helper may take (a catalog on a stalled disk): then it is stopped and the English name is shown.
    property int helperTimeoutMs: 3000

    // Test hook: the same path as the compositor's event.
    function feed(data: string): void {
        const event = Logic.parse(data);
        if (!event)
            return;
        const next = Logic.step(memory, event);
        memory = next.state;
        // A keyboard without layout names (a virtual one with its own keymap) is not an input source: nothing changes.
        if (!Logic.named(event.layout))
            return;
        layoutName = event.layout;
        if (next.show)
            announce(event.layout);
    }

    // Emits layoutChanged with the name in the shell's language: at once for English and for a name already looked up,
    // else once the helper has answered (the English name if it fails).
    function announce(english: string): void {
        const language = Translator.language;
        if (!Logic.needsLookup(language)) {
            layoutChanged(english);
            return;
        }
        const key = language + "|" + english;
        if (translated[key] !== undefined) {
            layoutChanged(translated[key]);
            return;
        }
        wanted = english;
        if (asking === "")
            ask();
    }

    // One helper at a time. A question asked while the previous helper has answered but not yet exited starts when it does.
    property bool startOnExit: false
    property string exitedFor: ""

    function ask(): void {
        asking = wanted;
        askingLanguage = Translator.language;
        lookup.command = ["python3", "-I", Quickshell.shellPath("platform/layout-names.py"), askingLanguage, asking];
        if (lookup.running)
            startOnExit = true;
        else
            lookup.running = true;
        helperTimeout.restart();
    }

    function answered(text: string): void {
        if (asking === "")
            return;
        helperTimeout.stop();
        const name = Logic.lookupResult(text, asking);
        const next = Object.assign({}, translated);
        next[askingLanguage + "|" + asking] = name;
        translated = next;
        const done = asking;
        asking = "";
        // The HUD shows the latest change only: a name asked for since replaces this one.
        if (wanted === done) {
            wanted = "";
            layoutChanged(name);
        } else if (wanted !== "") {
            announce(wanted);
        }
    }

    property Process lookup: Process {
        stdout: StdioCollector {
            onStreamFinished: root.answered(text)
        }
        // A helper that cannot start (or dies) answers nothing: the English name, a moment after the exit (the output, when
        // there is any, arrives first).
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // qmllint enable signal-handler-parameters
            if (root.startOnExit) {
                root.startOnExit = false;
                root.lookup.running = true;
            } else {
                // The question this helper was running for, if nobody has answered it yet.
                root.exitedFor = root.asking;
                root.giveUp.restart();
            }
        }
    }

    property Timer helperTimeout: Timer {
        interval: root.helperTimeoutMs
        onTriggered: {
            if (root.asking === "")
                return;
            // Stopped: the next question starts when it has exited; this one is answered in English now.
            root.startOnExit = false;
            root.lookup.signal(15);
            root.answered("");
        }
    }

    property Timer giveUp: Timer {
        interval: 250
        onTriggered: {
            if (root.asking !== "" && root.asking === root.exitedFor)
                root.answered("");
        }
    }

    property Connections events: Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "activelayout")
                root.feed(event.data);
        }
    }
}
