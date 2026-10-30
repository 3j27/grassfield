pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// One appearance thumbnail of Settings > Appearance (macOS 27 draws a small desktop: docs/audits/settings-parity-2026-10-26.md
// § Appearance): the Grassfield artwork with a menu bar strip, a menu at the top left whose selection is a bar in the accent,
// and a window at the bottom right with its three window buttons, running off the edges. `choice`: "light", "dark" or
// "auto" (light on the left half, dark on the right). The drawing's proportions are tokens (settings.appearanceThumb*).
Item {
    id: root

    property string choice: "light"

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
            color: Appearance.withAlpha(Tokens.colorDark.shadow, Tokens.settingsAppearanceThumbDarkWallpaper)
        }

        // The menu bar.
        Rectangle {
            width: parent.width
            height: Math.round(parent.height * Tokens.settingsAppearanceThumbBarHeight)
            color: Appearance.withAlpha(desktop.colors.materialTint, Tokens.settingsAppearanceThumbMenuOpacity)
        }

        // A menu, its selected item a bar in the accent.
        Rectangle {
            x: Math.round(parent.width * Tokens.settingsAppearanceThumbMenuX)
            y: Math.round(parent.height * Tokens.settingsAppearanceThumbMenuY)
            width: Math.round(parent.width * Tokens.settingsAppearanceThumbMenuWidth)
            height: Math.round(parent.height * Tokens.settingsAppearanceThumbMenuHeight)
            radius: Math.round(parent.height * Tokens.settingsAppearanceThumbMenuRadius)
            color: Appearance.withAlpha(desktop.colors.materialTint, Tokens.settingsAppearanceThumbMenuOpacity)

            Rectangle {
                x: Math.round(parent.parent.width * Tokens.settingsAppearanceThumbSelectionInset)
                y: x
                width: parent.width - 2 * x
                height: Math.max(1, Math.round(parent.parent.height * Tokens.settingsAppearanceThumbSelectionHeight))
                radius: height / 2
                color: Appearance.colors.accent
            }
        }

        // A window, running off the right and bottom edges, with its three buttons.
        Rectangle {
            x: Math.round(parent.width * Tokens.settingsAppearanceThumbWindowX)
            y: Math.round(parent.height * Tokens.settingsAppearanceThumbWindowY)
            width: parent.width - x + radius
            height: parent.height - y + radius
            radius: Math.round(parent.height * Tokens.settingsAppearanceThumbWindowRadius)
            color: desktop.colors.windowBackground
        }

        Repeater {
            model: [Tokens.windowCloseColor, Tokens.windowMinimizeColor, Tokens.windowZoomColor]

            delegate: Rectangle {
                required property color modelData
                required property int index

                width: Math.max(Tokens.settingsPictureMinimumPart, Math.round(desktop.width * Tokens.settingsAppearanceThumbLightSize))
                height: width
                radius: width / 2
                x: Math.round(desktop.width * Tokens.settingsAppearanceThumbLightX[index] - width / 2)
                y: Math.round(desktop.height * Tokens.settingsAppearanceThumbLightY - height / 2)
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
            x: Math.round(parent.width * Tokens.settingsAppearanceThumbAutoSplit)
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
