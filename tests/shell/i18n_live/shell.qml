import QtQuick
import Quickshell
import Grassfield.I18n

// Live language switch (docs/specs/i18n.md): the Translator singleton must hold the engine (it is created by
// its factory), so changing `language` re-evaluates the bindings of the running UI. Starts in English
// (GRASSFIELD_LANG=en), switches to fr, back to en; then the formats (region.formats) change the default locale only. Run by scripts/dev/test.sh (offscreen) as a dev session (the
// `dev-session` marker: the loader honours GRASSFIELD_TRANSLATIONS_DIR, this tree's catalogs, only in dev); prints
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
                // region.formats: the default locale changes, the words do not.
                Translator.formats = "de_DE";
            } else if (root.phase === 3) {
                // English in Germany: the German formats, the English words (macOS: the region never changes the words).
                root.check("formats de_DE: Qt.locale() formats", Qt.locale().name === "en_DE" && Qt.locale().toString(1234.5, "f", 1) === "1.234,5");
                root.check("formats de_DE: the words stay", Translator.language === "en" && root.rename === "Rename" && Qt.locale().dayName(1) === "Monday");
                Translator.language = "fr";
            } else if (root.phase === 4) {
                // Qt has no French in Germany: the region's own locale (its formats, its words).
                root.check("a language change keeps the formats", Qt.locale().name === "de_DE" && Qt.locale().toString(1234.5, "f", 1) === "1.234,5" && root.rename === "Renommer");
                Translator.formats = "de_DE; rm";
            } else if (root.phase === 5) {
                root.check("an invalid name is the language's formats", Qt.locale().name === "fr_FR");
                Translator.language = "en";
                Translator.formats = "auto";
            } else if (root.phase === 6) {
                root.check("auto: the language's formats", Qt.locale().name === "en_US" && root.rename === "Rename");
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
