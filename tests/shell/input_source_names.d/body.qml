pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.I18n
import qs.platform

// Body of tests/shell/input_source_names.sh (capture defect 10): the input source name in the shell's language. The helper
// reads a catalog of the test's own (GRASSFIELD_XKB_LOCALEDIR: "German" is "Allemand", "English (US)" is "Anglais (US)").
// English shows the compositor's name at once; French shows the translated one once the helper has answered, a name the
// catalog lacks stays English, and only the latest change is shown when two come quickly.
ShellRoot {
    id: root

    property var failures: []
    property var shown: []
    property int phase: 0
    property bool waiting: false
    property int waited: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Connections {
        target: InputSource

        function onLayoutChanged(name: string): void {
            root.shown.push(name);
        }
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            // A phase that waits for the helper moves on once its answer is in (a loaded machine takes a while).
            if (root.waiting && root.shown.length === 0 && root.waited++ < 100)
                return;
            root.waiting = false;
            root.waited = 0;
            switch (root.phase) {
            case 0:
                InputSource.feed("kbd0,English (US)");
                InputSource.feed("kbd0,German");
                root.check("en: the compositor's name, at once", root.shown.length === 1 && root.shown[0] === "German");
                Translator.language = "fr";
                root.shown = [];
                break;
            case 1:
                InputSource.feed("kbd0,English (US)");
                root.waiting = true;
                break;
            case 2:
                root.check("fr: the translated name", root.shown.length === 1 && root.shown[0] === "Anglais (US)");
                root.shown = [];
                InputSource.feed("kbd0,German");
                root.waiting = true;
                break;
            case 3:
                root.check("fr: another name", root.shown.length === 1 && root.shown[0] === "Allemand");
                root.shown = [];
                InputSource.feed("kbd0,Klingon (X)");
                InputSource.feed("kbd0,Klingon (Y)");
                root.waiting = true;
                break;
            case 4:
                root.check("fr: only the latest of two quick changes", root.shown.length === 1 && root.shown[0] === "Klingon (Y)");
                root.shown = [];
                InputSource.feed("kbd0,German");
                // The answer is cached: shown at once.
                root.check("fr: a name already looked up is immediate", root.shown.length === 1 && root.shown[0] === "Allemand");
                root.shown = [];
                InputSource.feed("kbd0,English (US)");
                root.check("fr: and the other one", root.shown.length === 1 && root.shown[0] === "Anglais (US)");
                root.shown = [];
                InputSource.feed("wtype,error");
                break;
            default:
                root.check("fr: error shows nothing", root.shown.length === 0);
                running = false;
                if (root.failures.length === 0) {
                    console.log("PASS: input_source_names");
                    Qt.exit(0);
                } else {
                    console.log("FAIL: input_source_names " + root.failures.join(", ") + " shown=" + JSON.stringify(root.shown));
                    Qt.exit(1);
                }
                return;
            }
            root.phase++;
        }
    }
}
