pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Hyprland
import Quickshell.Io
import "ConfigErrors.js" as Logic

// Hyprland's config errors (ADR-0035 D-2, step 3). This reads `hyprctl -j configerrors` when the shell starts and after
// each config reload, and the shell root shows one notice per new set of errors ("Some settings could not be applied", the
// lines in its body) and withdraws it once they are gone. The decisions are ConfigErrors.js. Hyprland's red error bar stays
// on: on 0.56.2 under the Lua config the answer is always empty (every dispatch clears the errors; decision 3-15).
Item {
    id: root

    // Overridable for tests.
    property var queryCommand: ["hyprctl", "-j", "configerrors"]
    // The key of the set the notice on screen is for ("" when there is none).
    property string shownKey: ""
    property bool readAgain: false

    // A new set of errors: the first lines and how many more.
    signal appeared(var lines, int more)
    // The errors are gone.
    signal cleared

    visible: false

    // The notice's body for these lines and the "and N more" text ("" for none).
    function noticeBody(lines: var, rest: string): string {
        return Logic.noticeBody(lines, rest);
    }

    function read(): void {
        if (query.running) {
            root.readAgain = true;
            return;
        }
        query.running = true;
    }

    function take(text: string): void {
        const errors = Logic.parse(text);
        switch (Logic.action(errors, root.shownKey)) {
        case "post":
            {
                root.shownKey = Logic.key(errors);
                const s = Logic.summary(errors);
                // The count only: the lines can name the user's files.
                console.info("grassfield: Hyprland config errors: " + errors.length);
                root.appeared(s.lines, s.more);
                break;
            }
        case "clear":
            root.shownKey = "";
            root.cleared();
            break;
        }
    }

    Component.onCompleted: root.read()

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "configreloaded")
                root.read();
        }
    }

    Process {
        id: query
        command: root.queryCommand
        stdout: StdioCollector {
            onStreamFinished: root.take(text)
        }
        // A reload while the last read ran: read once more.
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (root.readAgain) {
                root.readAgain = false;
                root.read();
            }
        }
        // qmllint enable signal-handler-parameters
    }
}
