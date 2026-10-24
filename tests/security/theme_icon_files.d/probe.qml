pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.notifications
import qs.services

// Probe of tests/security/theme_icon_files.sh (review of 2dfd992). The script planted files for the theme icon name
// "evil" (PROBE_KIND says which) and a regular icon "ctl" in a scratch XDG_DATA_DIRS entry. As a notification would, it
// takes "evil" in as an app icon, waits for ThemeIcons' verdict, gives the notification's icon source and the polkit
// sheet's (ThemeIcons.source, AuthAgent's call) to Images, then loads "ctl": that Image only becomes Ready when the one
// image loader never stalled. Prints one "probe:" line and exits.
ShellRoot {
    id: root

    readonly property string kind: Quickshell.env("PROBE_KIND")
    property string phase: "verdict"
    property int waited: 0
    property string verdict: ""
    property string notifSource: ""
    property string polkitSource: ""

    Component.onCompleted: {
        Notifications.checkedAppIcon("evil");
        poll.start();
    }

    FloatingWindow {
        visible: true
        implicitWidth: 96
        implicitHeight: 32

        Image {
            id: viaNotification
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(256, 256)
        }

        Image {
            id: viaPolkit
            x: 32
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(128, 128)
        }

        Image {
            id: control
            x: 64
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(64, 64)
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "verdict") {
                const v = ThemeIcons.verdicts["evil"];
                if ((v === undefined || v === "pending") && root.waited < 10000)
                    return;
                root.verdict = String(v);
                root.notifSource = Notifications.iconSource("", "evil");
                root.polkitSource = ThemeIcons.source("evil");
                viaNotification.source = root.notifSource;
                viaPolkit.source = root.polkitSource;
                ThemeIcons.check("ctl", false);
                root.phase = "control";
                root.waited = 0;
            } else if (root.phase === "control") {
                // At least a second after "evil" was handed to the loader, so a stalled read has started.
                const c = ThemeIcons.source("ctl");
                if ((c === "" || root.waited < 1000) && root.waited < 10000)
                    return;
                control.source = c;
                root.phase = "loaded";
                root.waited = 0;
            } else if (root.phase === "loaded") {
                if (control.status !== Image.Ready && root.waited < 5000)
                    return;
                stop();
                console.log("probe: kind=" + root.kind + " verdict=" + root.verdict + " notif=" + root.notifSource + " polkit=" + root.polkitSource
                    + " evil=" + viaNotification.status + " ctl=" + control.status);
                Qt.exit(0);
            }
        }
    }
}
