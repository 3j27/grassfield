import QtQuick
import Quickshell
import Grassfield.I18n
import qs.services

// Apps.qml's names in the shell's language (run by tests/shell/entry_names.sh with LANG=en_US.UTF-8 and GRASSFIELD_LANG=fr_FR, on an XDG
// tree holding copies of the Grassfield desktop entries): Quickshell picks the English values from LANG, the shell is French,
// so the names the shell shows must become the French ones, and the English ones again when the language changes. Prints
// "entry-names-live: PASS" or a FAIL line.
ShellRoot {
    id: root

    // id -> [French name, English name]
    readonly property var expected: ({
            "org.grassfield.Files": ["Fichiers", "Files"],
            "org.grassfield.Settings": ["Réglages Grassfield", "Grassfield Settings"],
            "org.grassfield.Preview": ["Visionneuse", "Preview"]
        })
    property string phase: "fr"
    property bool quickshellEnglish: false

    function names(index: int): bool {
        for (const id in root.expected) {
            if (Apps.nameFor(id) !== root.expected[id][index])
                return false;
        }
        return true;
    }

    function report(): string {
        return Object.keys(root.expected).map(id => id + "=" + Apps.nameFor(id)).join(", ");
    }

    Component.onCompleted: console.log("entry-names-live: shell language " + Translator.language)

    // Quickshell's own pick, before the shell writes anything: what a French session showed before this fix.
    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            const e = DesktopEntries.byId("org.grassfield.Files");
            if (e && root.phase === "fr" && !root.quickshellEnglish && e.genericName === "File Manager")
                root.quickshellEnglish = true;
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        property int ticks: 0
        onTriggered: {
            ticks++;
            if (root.phase === "fr" && root.names(0)) {
                const e = DesktopEntries.byId("org.grassfield.Files");
                const extras = Apps.displayGenericName(e) === "Gestionnaire de fichiers" && Apps.displayKeywords(e).indexOf("dossier") >= 0;
                console.log("entry-names-live: French names " + root.report() + (extras ? ", generic name and keywords French" : ""));
                if (!extras) {
                    console.log("entry-names-live: FAIL generic name or keywords not French: " + Apps.displayGenericName(e) + " / " + Apps.displayKeywords(e));
                    Qt.quit();
                }
                root.phase = "en";
                ticks = 0;
                Translator.language = "en_US";
            } else if (root.phase === "en" && root.names(1)) {
                console.log("entry-names-live: English names after the language changed " + root.report());
                console.log("entry-names-live: " + (root.quickshellEnglish ? "PASS" : "FAIL Quickshell's own pick was never seen English (the mismatch was not reproduced)"));
                Qt.quit();
            } else if (ticks > 80) {
                console.log("entry-names-live: FAIL in phase " + root.phase + ": " + root.report());
                Qt.quit();
            }
        }
    }
}
