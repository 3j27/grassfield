pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.I18n
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
import qs.switcher

// grassfield-shell root. Settings feed the design-system Appearance singleton; surfaces
// read Appearance and Tokens only.
ShellRoot {
    id: root

    // Never reload on file changes: a reload is a security event for the session lock (R12,
    // shell/security/lock/Lock.qml). Re-applied by every reload (Quickshell resets it to true).
    // Development restarts the shell instead (scripts/dev/shell-run.sh).
    settings.watchFiles: false

    // Instantiates the Translator singleton first: it installs the catalog (GRASSFIELD_LANG or system
    // locale) before the surfaces below evaluate their qsTr() strings.
    readonly property string language: Translator.language

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

    Binding {
        target: Appearance
        property: "iconMode"
        value: Settings.iconMode
    }

    Binding {
        target: Appearance
        property: "iconTintSetting"
        value: Settings.iconTint
    }

    // One degraded-mode notice when the compositor extension never answered; withdrawn if it loads later.
    property string degradedNoticeKey: ""

    // The degraded notice is shown once while the compositor extension is absent and withdrawn when it is present.
    function syncDegradedNotice(): void {
        if (Capabilities.settled && !Capabilities.pluginPresent && degradedNoticeKey === "") {
            degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension not loaded"), qsTr("Window titlebars and minimize are unavailable (compositor extension not loaded)."));
        } else if (Capabilities.pluginPresent && degradedNoticeKey !== "") {
            Notifications.clear(degradedNoticeKey);
            degradedNoticeKey = "";
        }
    }

    Connections {
        target: SettingsApp

        function onMissing(): void {
            Notifications.postInternal(qsTr("Grassfield Settings is not installed"), qsTr("Install the grassfield-desktop package to open Settings."));
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
            root.syncDegradedNotice();
        }

        // Also when the plugin goes away later (unload: empty capabilities event).
        function onPluginPresentChanged(): void {
            root.syncDegradedNotice();
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
    Search {
        id: searchSurface
    }
    AuthAgent {}
    Idle {}
    Overview {
        id: overviewSurface
    }
    AppsController {
        id: appsSurface
    }
    Switcher {
        id: switcher
        // The session lock owns the screen and the keyboard: the switcher ends and does not start.
        locked: Lock.lockState !== "unlocked"
    }
    SwitcherWindow {
        controller: switcher
    }

    // Opening Overview, Apps, Search or the app switcher closes the others: the keyboard follows the visible top surface.
    ExclusiveSurfaces {
        surfaces: [
            {target: overviewSurface, close: () => overviewSurface.requestClose()},
            {target: appsSurface, close: () => appsSurface.hide()},
            {target: searchSurface, close: () => searchSurface.hide()},
            {target: switcher, close: () => switcher.cancel()}
        ]
    }

    // Referencing Capabilities instantiates it, which sends the plugin hello; referencing Lock
    // instantiates the session lock (IPC target "lock", crash-recovery restore).
    Component.onCompleted: console.info("grassfield-shell: started, plugin protocol", Capabilities.protocol, "lock", Lock.lockState)
}
