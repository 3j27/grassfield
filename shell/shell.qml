pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.desktop
import qs.dock
import qs.launchpad
import qs.menubar
import qs.notifications
import qs.osd
import qs.overview
import qs.overlay
import qs.platform
import qs.search
import qs.security.idle
import qs.security.lock
import qs.security.polkit
import qs.services

// grassfield-shell root. Settings feed the design-system Appearance singleton; surfaces
// read Appearance and Tokens only.
ShellRoot {
    id: root

    // Never reload on file changes: a reload is a security event for the session lock (R12,
    // shell/security/lock/Lock.qml). Re-applied by every reload (Quickshell resets it to true).
    // Development restarts the shell instead (scripts/dev/shell-run.sh).
    settings.watchFiles: false

    Binding {
        target: Appearance
        property: "dark"
        value: Settings.dark
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: Settings.transparency
    }

    Binding {
        target: Appearance
        property: "reduceTransparency"
        value: Settings.reduceTransparency
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: Settings.reduceMotion
    }

    // One degraded-mode notice when the compositor extension never answered; withdrawn if it loads later.
    property string degradedNoticeKey: ""

    Connections {
        target: SettingsApp

        function onMissing(): void {
            Notifications.postInternal(qsTr("Grassfield Settings is not installed"), qsTr("Install the grassfield-desktop package to open System Settings."));
        }
    }

    Connections {
        target: GlanceApp

        function onMissing(): void {
            Notifications.postInternal(qsTr("Glance is not available"), qsTr("Install the grassfield-desktop package to preview files with Space."));
        }
    }

    Connections {
        target: Capabilities

        function onSettledChanged(): void {
            if (Capabilities.settled && !Capabilities.pluginPresent && root.degradedNoticeKey === "")
                root.degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension not loaded"), qsTr("Window titlebars and minimize are unavailable (compositor extension not loaded)."));
        }

        function onPluginPresentChanged(): void {
            if (Capabilities.pluginPresent && root.degradedNoticeKey !== "") {
                Notifications.clear(root.degradedNoticeKey);
                root.degradedNoticeKey = "";
            }
        }
    }

    Wallpaper {}
    HotCorners {}
    DesktopIcons {}
    DesktopWidgets {}
    MenuBar {}
    Dock {}
    Overlay {}
    Banners {}
    NotificationCenter {}
    OsdWindow {}
    Search {}
    AuthAgent {}
    Idle {}
    Overview {}
    AppsController {}

    // Referencing Capabilities instantiates it, which sends the plugin hello; referencing Lock
    // instantiates the session lock (IPC target "lock", crash-recovery restore).
    Component.onCompleted: console.info("grassfield-shell: started, plugin protocol", Capabilities.protocol, "lock", Lock.lockState)
}
