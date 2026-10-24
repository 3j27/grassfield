import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n

// Probe of tests/security/theme_icon_files.sh, part 4: the shell's icon search policy (ui/i18n/iconsearchpaths.h,
// applied when Grassfield.I18n is imported). The script planted REGULAR icon files that Qt finds and reads without the
// policy, offscreen too (so this part can fail): "useronly" in the user's hicolor folder, "evilpix" in a user-writable
// XDG_DATA_DIRS pixmaps folder (Qt's fallback search path), "usertheme" in a user theme named by QS_ICON_THEME. The
// probe asks Qt for each (Quickshell.hasThemeIcon) and loads each by its image://icon URL, as an Image would (the
// script logs every open of this process and its children); with the policy, Qt finds none and opens none of their
// files. It also checks that a child process (as an application launched from the shell would be) gets the shell's
// environment unchanged: the policy changes no variable. Prints "probe:" lines and exits.
ShellRoot {
    id: root

    readonly property string expected: [Quickshell.env("HOME"), Quickshell.env("XDG_DATA_HOME"), Quickshell.env("XDG_DATA_DIRS")].join("|")
    readonly property var names: ["useronly", "evilpix", "usertheme", "folder"]
    property int waited: 0

    Component.onCompleted: {
        for (const name of names)
            console.log("probe: " + name + " has=" + Quickshell.hasThemeIcon(name));
        loads.model = names.map(n => "image://icon/" + n);
    }

    FloatingWindow {
        visible: true
        implicitWidth: 200
        implicitHeight: 40

        Row {
            Repeater {
                id: loads

                Image {
                    required property string modelData
                    width: 16
                    height: 16
                    asynchronous: true
                    source: modelData
                }
            }
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.waited += interval;
            let loading = false;
            for (let i = 0; i < loads.count; i++)
                loading = loading || (loads.itemAt(i) as Image).status === Image.Loading;
            if ((loading || root.waited < 1000) && root.waited < 10000)
                return;
            stop();
            const statuses = [];
            for (let i = 0; i < loads.count; i++)
                statuses.push(root.names[i] + "=" + (loads.itemAt(i) as Image).status);
            console.log("probe: loaded " + statuses.join(" "));
            child.running = true;
        }
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
