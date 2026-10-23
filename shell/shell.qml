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
        property: "increaseContrast"
        value: Settings.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: Settings.textSize
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: Settings.accentColor
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

    Binding {
        target: Appearance
        property: "folderColorSetting"
        value: Settings.folderColor
    }

    // Pointer size (Settings > Accessibility > Pointer): the compositor is asked for the new size live.
    Binding {
        target: Pointer
        property: "size"
        value: Settings.pointerSize
    }

    // Pointer colours: the cursor theme is regenerated (debounced, off the UI thread) and switched to; the state of the
    // build is written next to grassfield.json for the Settings app.
    Binding {
        target: Pointer
        property: "outlineColor"
        value: Settings.pointerOutlineColor
    }

    Binding {
        target: Pointer
        property: "fillColor"
        value: Settings.pointerFillColor
    }

    // The colours are the stored ones only once the file is read (a custom theme from an earlier session is kept until then).
    Binding {
        target: Pointer
        property: "colorsKnown"
        value: Settings.validRead
    }

    // A malformed grassfield.json is not a read: the compositor theme and the custom theme on disk stay as they are.
    Binding {
        target: Pointer
        property: "settingsFailed"
        value: Settings.writeBlocked
    }

    Binding {
        target: Pointer
        property: "statusPath"
        value: Settings.configDir + "/pointer-theme.json"
    }

    // One degraded-mode notice when the compositor extension is absent; withdrawn if it loads later.
    property string degradedNoticeKey: ""

    // The degraded notice is shown once the compositor extension is known to be absent (Capabilities.absent: not at the
    // first timeout, a loaded plugin can answer late at login) and withdrawn when it is present.
    function syncDegradedNotice(): void {
        if (Capabilities.absent && degradedNoticeKey === "") {
            console.info("grassfield: degraded notice posted (compositor extension absent)");
            degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension not loaded"), qsTr("Window titlebars and minimize are unavailable (compositor extension not loaded)."));
        } else if (!Capabilities.absent && degradedNoticeKey !== "") {
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

        // No reply for helloAbsentMs, an unload (empty capabilities event), or a plugin that loads after the notice.
        function onAbsentChanged(): void {
            root.syncDegradedNotice();
        }
    }

    Wallpaper {}
    HotCorners {}
    DesktopIcons {}
    DesktopWidgets {}
    MenuBar {
        searchActive: searchSurface.open
        onSearchRequested: searchSurface.toggle()
    }
    Dock {
        onAppsRequested: appsSurface.toggle()
    }
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
        // The session lock owns the screen and the keyboard: the overview closes and focuses nothing.
        locked: Lock.lockState !== "unlocked"
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
            {target: overviewSurface, close: () => overviewSurface.requestCloseForOther()},
            {target: appsSurface, close: () => appsSurface.hide()},
            {target: searchSurface, close: () => searchSurface.hide()},
            {target: switcher, close: () => switcher.cancel()}
        ]
    }

    // Referencing Capabilities instantiates it, which sends the plugin hello; referencing Lock
    // instantiates the session lock (IPC target "lock", crash-recovery restore); referencing RecentItems makes it listen to
    // every launch from the start (it would otherwise exist only once the Grassfield menu opened).
    Component.onCompleted: console.info("grassfield-shell: started, version", SystemInfo.grassfieldVersion, "plugin protocol", Capabilities.protocol, "lock", Lock.lockState, "recent items", RecentItems.max)
}
