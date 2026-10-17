pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.desktop
import qs.dock
import qs.menubar
import qs.notifications
import qs.osd
import qs.overlay
import qs.platform
import qs.search
import qs.services

// grassfield-shell root. Settings feed the design-system Appearance singleton; surfaces
// read Appearance and Tokens only.
ShellRoot {
    id: root

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

    // One degraded-mode notice when the compositor extension never answered.
    Connections {
        target: Capabilities

        function onSettledChanged(): void {
            if (Capabilities.settled && !Capabilities.pluginPresent)
                Notifications.postInternal(qsTr("Compositor extension not loaded"), qsTr("Window titlebars and minimize are unavailable (compositor extension not loaded)."));
        }
    }

    Wallpaper {}
    MenuBar {}
    Dock {}
    Overlay {}
    Banners {}
    NotificationCenter {}
    OsdWindow {}
    Search {}

    // Referencing Capabilities instantiates it, which sends the plugin hello.
    Component.onCompleted: console.info("grassfield-shell: started, plugin protocol", Capabilities.protocol)
}
