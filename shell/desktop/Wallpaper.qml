pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// Desktop wallpaper: the Grassfield artwork (WallpaperArt) on the background layer of every screen.
Variants {
    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        screen: modelData
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        color: artwork.art.skyTop
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "grassfield-wallpaper"

        HoverHandler {
            onPointChanged: if (hovered)
                PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
        }

        WallpaperArt {
            id: artwork
            anchors.fill: parent
        }
    }
}
