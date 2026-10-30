import QtQuick
import Quickshell
import Grassfield.I18n
import Grassfield.Ui
import "platform/MenuBridge.js" as Bridge

// An application's menu shortcut in the shell's language (capture defect 2): the bridge's key names are translated with the
// shipped catalog, the way the shell's own menus carry theirs, and the macOS style turns the same words into the symbols
// (MenuShortcut.label), so an app's menu and the shell's look the same in French. Run by scripts/dev/test.sh (offscreen,
// a dev session for the catalog); prints "menu-shortcut-fr: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []

    function check(name: string, got: string, want: string): void {
        if (got !== want)
            failures.push(name + ": got '" + got + "', want '" + want + "'");
    }

    function text(keys: var): string {
        return Bridge.shortcutText([keys]);
    }

    Timer {
        interval: 50
        running: true
        onTriggered: {
            root.check("en: new folder", root.text(["Control", "Shift", "N"]), "Ctrl+Shift+N");
            Translator.language = "fr";
            root.check("fr: new folder", root.text(["Control", "Shift", "N"]), "Ctrl+Maj+N");
            root.check("fr: backspace", root.text(["Control", "BackSpace"]), "Ctrl+Retour arrière");
            root.check("fr: tab", root.text(["Control", "Shift", "Tab"]), "Ctrl+Maj+Tab");
            root.check("fr: delete", root.text(["Delete"]), "Suppr");
            root.check("fr: escape", root.text(["Escape"]), "Échap");
            root.check("fr: return", root.text(["Alt", "Return"]), "Alt+Entrée");
            root.check("fr: arrows", root.text(["Super", "Control", "Left"]), "Super+Ctrl+Gauche");
            root.check("fr: page up", root.text(["Control", "Page_Up"]), "Ctrl+Page préc.");
            root.check("fr: home", root.text(["Home"]), "Début");
            root.check("fr: plus stays", root.text(["Control", "plus"]), "Ctrl++");
            root.check("fr: letters stay upper case", root.text(["Control", "n"]), "Ctrl+N");
            // The macOS style reads those French names back as the symbols (language neutral).
            const mac = k => MenuShortcut.label(root.text(k), "mac");
            root.check("mac: new folder", mac(["Control", "Shift", "N"]), "⌃⇧N");
            root.check("mac: backspace", mac(["Control", "BackSpace"]), "⌃⌫");
            root.check("mac: shift tab", mac(["Control", "Shift", "Tab"]), "⌃⇧⇥");
            root.check("mac: delete", mac(["Delete"]), "⌦");
            root.check("mac: escape", mac(["Escape"]), "⎋");
            root.check("mac: return", mac(["Alt", "Return"]), "⌥↩");
            root.check("mac: super arrow", mac(["Super", "Control", "Left"]), "⌃⌘←");
            root.check("mac: page up", mac(["Control", "Page_Up"]), "⌃⇞");
            root.check("mac: home", mac(["Home"]), "↖");
            // Qt applications (Grassfield's own, apps/globalmenu.h) send Qt's names: the strings of QKeySequence::toString(PortableText),
            // from Qt's key name table (qkeysequence.cpp: Space, Esc, Tab, Backtab, Backspace, Return, Enter, Ins, Del, Print, Home,
            // End, Left, Up, Right, Down, PgUp, PgDown), in any case.
            root.check("fr qt: trash", root.text(["Ctrl", "Backspace"]), "Ctrl+Retour arrière");
            root.check("fr qt: delete", root.text(["Del"]), "Suppr");
            root.check("fr qt: esc", root.text(["Esc"]), "Échap");
            root.check("fr qt: pgup", root.text(["Ctrl", "PgUp"]), "Ctrl+Page préc.");
            root.check("fr qt: pgdown", root.text(["Ctrl", "PgDown"]), "Ctrl+Page suiv.");
            root.check("fr qt: ins", root.text(["Ins"]), "Inser");
            root.check("fr qt: space", root.text(["Space"]), "Espace");
            root.check("fr qt: print", root.text(["Print"]), "Impr. écran");
            root.check("fr qt: return", root.text(["Ctrl", "Return"]), "Ctrl+Entrée");
            root.check("fr qt: enter", root.text(["Enter"]), "Entrée");
            root.check("fr qt: arrows", root.text(["Alt", "Left"]), "Alt+Gauche");
            root.check("fr qt: meta", root.text(["Meta", "L"]), "Super+L");
            root.check("fr qt: f5", root.text(["f5"]), "F5");
            root.check("fr qt: lower case", root.text(["ctrl", "backspace"]), "Ctrl+Retour arrière");
            root.check("mac qt: trash", mac(["Ctrl", "Backspace"]), "⌃⌫");
            root.check("mac qt: pgdown", mac(["Ctrl", "PgDown"]), "⌃⇟");
            // The shell's own menus carry the same words: the same shortcut written either way is the same label.
            root.check("shell and app agree", MenuShortcut.label(qsTranslate("AppMenuModel", "Super+Ctrl+Left"), "mac"), mac(["Super", "Control", "Left"]));
            if (root.failures.length === 0) {
                console.log("menu-shortcut-fr: PASS");
                Qt.exit(0);
            } else {
                console.log("menu-shortcut-fr: FAIL " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }
}
