pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.services

// Desktop wallpaper: the Grassfield artwork (WallpaperArt) on the background layer of every screen.
Scope {
    id: root

    // Dev-only wallpaper override for tests/visual (contrast on worst-case wallpapers): with
    // GRASSFIELD_DEV=1, GRASSFIELD_WALLPAPER_FILE (initial) or `qs ipc call wallpaper set <png>` covers
    // the artwork with that image; an empty path restores the artwork. Inert outside dev.
    readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1"
    property string overrideFile: dev ? Quickshell.env("GRASSFIELD_WALLPAPER_FILE") : ""

    IpcHandler {
        target: "wallpaper"

        function set(path: string): string {
            if (!root.dev)
                return "refused";
            root.overrideFile = path;
            return "ok";
        }
    }

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

            Image {
                anchors.fill: parent
                visible: root.overrideFile !== ""
                source: root.overrideFile !== "" ? "file://" + root.overrideFile : ""
                fillMode: Image.Stretch
                cache: false
                smooth: false
            }
        }
    }
}
