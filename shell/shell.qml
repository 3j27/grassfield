pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.desktop
import qs.dock
import qs.menubar
import qs.overlay
import qs.platform
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

    Wallpaper {}
    MenuBar {}
    Dock {}
    Overlay {}

    // Referencing Capabilities instantiates it, which sends the plugin hello.
    Component.onCompleted: console.info("grassfield-shell: started, plugin protocol", Capabilities.protocol)
}
