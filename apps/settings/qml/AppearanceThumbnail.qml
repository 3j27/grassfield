pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// One appearance thumbnail of Settings > Appearance (macOS 27 draws a small desktop: docs/audits/settings-parity-2026-10-26.md
// § Appearance): the Grassfield artwork with a menu bar strip, a menu at the top left whose selection is a bar in the accent,
// and a window at the bottom right with its three window buttons, running off the edges. `choice`: "light", "dark" or
// "auto" (light on the left half, dark on the right). The proportions below are the drawing's, not UI metrics.
Item {
    id: root

    property string choice: "light"

    readonly property var art: ({
            barHeight: 0.1,
            menuX: 0.02,
            menuY: 0.17,
            menuWidth: 0.57,
            menuHeight: 0.3,
            menuRadius: 0.06,
            selectionInset: 0.035,
            selectionHeight: 0.11,
            windowX: 0.26,
            windowY: 0.56,
            windowRadius: 0.12,
            lightY: 0.8,
            lightSize: 0.09,
            lightX: [0.42, 0.56, 0.7],
            autoSplit: 0.49,
            darkWallpaper: 0.35,
            menuOpacity: 0.72
        })

    component Desktop: Item {
        id: desktop

        property bool dark: false
        readonly property var colors: desktop.dark ? Tokens.colorDark : Tokens.colorLight

        GrassfieldArtwork {
            anchors.fill: parent
        }

        // The dark appearance's wallpaper is the darker one.
        Rectangle {
            anchors.fill: parent
            visible: desktop.dark
            color: Appearance.withAlpha(Tokens.colorDark.shadow, root.art.darkWallpaper)
        }

        // The menu bar.
        Rectangle {
            width: parent.width
            height: Math.round(parent.height * root.art.barHeight)
            color: Appearance.withAlpha(desktop.colors.materialTint, root.art.menuOpacity)
        }

        // A menu, its selected item a bar in the accent.
        Rectangle {
            x: Math.round(parent.width * root.art.menuX)
            y: Math.round(parent.height * root.art.menuY)
            width: Math.round(parent.width * root.art.menuWidth)
            height: Math.round(parent.height * root.art.menuHeight)
            radius: Math.round(parent.height * root.art.menuRadius)
            color: Appearance.withAlpha(desktop.colors.materialTint, root.art.menuOpacity)

            Rectangle {
                x: Math.round(parent.parent.width * root.art.selectionInset)
                y: x
                width: parent.width - 2 * x
                height: Math.max(1, Math.round(parent.parent.height * root.art.selectionHeight))
                radius: height / 2
                color: Appearance.colors.accent
            }
        }

        // A window, running off the right and bottom edges, with its three buttons.
        Rectangle {
            x: Math.round(parent.width * root.art.windowX)
            y: Math.round(parent.height * root.art.windowY)
            width: parent.width - x + radius
            height: parent.height - y + radius
            radius: Math.round(parent.height * root.art.windowRadius)
            color: desktop.colors.windowBackground
        }

        Repeater {
            model: [Tokens.windowCloseColor, Tokens.windowMinimizeColor, Tokens.windowZoomColor]

            delegate: Rectangle {
                required property color modelData
                required property int index

                width: Math.max(2, Math.round(desktop.width * root.art.lightSize))
                height: width
                radius: width / 2
                x: Math.round(desktop.width * root.art.lightX[index] - width / 2)
                y: Math.round(desktop.height * root.art.lightY - height / 2)
                color: modelData
            }
        }
    }

    Item {
        id: picture
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
        }

        Desktop {
            anchors.fill: parent
            dark: root.choice === "dark"
        }

        // Auto: the dark desktop on the right part.
        Item {
            visible: root.choice === "auto"
            x: Math.round(parent.width * root.art.autoSplit)
            width: parent.width - x
            height: parent.height
            clip: true

            Desktop {
                x: -parent.x
                width: picture.width
                height: picture.height
                dark: true
            }
        }
    }

    Rectangle {
        id: mask
        visible: false
        layer.enabled: true
        width: root.width
        height: root.height
        radius: Tokens.settingsAppearanceThumbRadius
    }

    // The edge of a thumbnail that is not chosen (the chosen one has its accent ring).
    Rectangle {
        anchors.fill: parent
        radius: Tokens.settingsAppearanceThumbRadius
        color: "transparent"
        border.width: Tokens.appsBorderWidth
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }
}
