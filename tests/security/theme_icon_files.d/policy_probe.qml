import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n

// Probe of tests/security/theme_icon_files.sh, part 4: the shell's icon search policy (ui/i18n/iconsearchpaths.h,
// applied when Grassfield.I18n is imported). Asks Qt for icons whose only files sit in the user's icon folders next to
// FIFO index.theme and icon-theme.cache files (the script logs every open of this process and its children), and checks
// that a child process (as an application launched from the shell would be) gets the shell's environment unchanged:
// the policy changes no variable. Prints "probe:" lines and exits.
ShellRoot {
    id: root

    readonly property string expected: [Quickshell.env("HOME"), Quickshell.env("XDG_DATA_HOME"), Quickshell.env("XDG_DATA_DIRS")].join("|")

    Component.onCompleted: {
        for (const name of ["useronly", "evil", "folder", "user-trash"])
            console.log("probe: " + name + " has=" + Quickshell.hasThemeIcon(name));
        child.running = true;
    }

    Process {
        id: child
        command: ["sh", "-c", "printf '%s|%s|%s' \"$HOME\" \"$XDG_DATA_HOME\" \"$XDG_DATA_DIRS\""]
        stdout: StdioCollector {
            onStreamFinished: {
                console.log("probe: child environment same=" + (text === root.expected));
                Qt.exit(0);
            }
        }
    }
}
