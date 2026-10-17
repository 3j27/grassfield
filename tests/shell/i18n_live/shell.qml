import QtQuick
import Quickshell
import Grassfield.I18n

// Live language switch (docs/specs/i18n.md): the Translator singleton must hold the engine (it is created by
// its factory), so changing `language` re-evaluates the bindings of the running UI. Starts in English
// (GRASSFIELD_LANG=en), switches to fr, back to en. Run by scripts/dev/test.sh (offscreen); prints
// "i18n-live: PASS" or the failures. Uses a string of the shipped catalog (context IconMenu).
ShellRoot {
    id: root

    property var failures: []
    property int phase: 0
    readonly property string rename: qsTranslate("IconMenu", "Rename")

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Timer {
        interval: 50
        running: true
        repeat: true
        onTriggered: {
            if (root.phase === 0) {
                root.check("starts in English", Translator.language === "en" && root.rename === "Rename");
                Translator.language = "fr";
            } else if (root.phase === 1) {
                root.check("fr: binding re-evaluated", root.rename === "Renommer");
                Translator.language = "en";
            } else if (root.phase === 2) {
                root.check("en again: binding re-evaluated", root.rename === "Rename");
            } else {
                running = false;
                if (root.failures.length === 0) {
                    console.log("i18n-live: PASS");
                    Qt.exit(0);
                } else {
                    console.log("i18n-live: FAIL " + root.failures.join(", "));
                    Qt.exit(1);
                }
            }
            root.phase++;
        }
    }
}
