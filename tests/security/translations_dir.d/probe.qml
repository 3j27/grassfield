import QtQuick
import Quickshell
import Grassfield.I18n

// Probe of tests/security/translations_dir.sh: switches the live language to French (Grassfield.I18n loads
// grassfield_fr.qm from the loader's catalog directory) and prints the French string of a shipped source string
// (context IconMenu, "Rename"). The script's hostile catalog translates it to "HOSTILE". Prints one "translations:" line.
ShellRoot {
    id: root

    readonly property string rename: qsTranslate("IconMenu", "Rename")

    Timer {
        interval: 200
        running: true
        onTriggered: {
            Translator.language = "fr";
            Qt.callLater(() => {
                console.log("translations: rename=" + root.rename);
                Qt.exit(0);
            });
        }
    }
}
