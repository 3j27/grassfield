pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// One screen saver's picture in Settings > Wallpaper > Screen Saver (ADR-0032), drawn the way the shell draws it
// (shell/saver/SaverView.qml): `choice` "artwork" (the Grassfield artwork), "wallpaperClock" (the artwork dimmed under the
// time), "slideshow" (a stack of pictures) or "clock" (the time on black). The proportions below are the drawing's, not UI
// metrics.
Item {
    id: root

    property string choice: "artwork"

    readonly property var art: ({
            clockSize: 0.3,
            clockOnlyX: 0.18,
            clockOnlyY: 0.3,
            photoInset: 0.14,
            photoTilt: 7,
            photoBorder: 0.04
        })
    readonly property string time: Qt.formatTime(new Date(), /a/i.test(Qt.locale().timeFormat(Locale.ShortFormat)) ? "h:mm" : "H:mm")

    component Time: Text {
        textFormat: Text.PlainText
        text: root.time
        color: Tokens.colorDark.text
        font.family: Appearance.fontFamily
        font.pixelSize: Math.max(1, Math.round(root.height * root.art.clockSize))
        font.weight: Tokens.saverClockWeight
    }

    Item {
        id: picture
        anchors.fill: parent
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
        }

        Rectangle {
            anchors.fill: parent
            color: Tokens.colorDark.shadow
        }

        GrassfieldArtwork {
            anchors.fill: parent
            visible: root.choice === "artwork" || root.choice === "wallpaperClock"
        }

        // The wallpaper with a clock: dimmed as the shell dims it, the time in the middle.
        Rectangle {
            anchors.fill: parent
            visible: root.choice === "wallpaperClock"
            color: Tokens.colorDark.shadow
            opacity: Tokens.saverWallpaperDimOpacity
        }

        Time {
            anchors.centerIn: parent
            visible: root.choice === "wallpaperClock"
        }

        // The clock alone on black, off the centre (it moves every minute).
        Time {
            visible: root.choice === "clock"
            x: Math.round(parent.width * root.art.clockOnlyX)
            y: Math.round(parent.height * root.art.clockOnlyY)
            opacity: Tokens.saverClockOnlyOpacity
        }

        // The slideshow: two pictures, the back one tilted.
        Repeater {
            model: root.choice === "slideshow" ? [-root.art.photoTilt, 0] : []

            delegate: Rectangle {
                required property real modelData

                anchors.centerIn: parent
                width: Math.round(parent.width * (1 - 2 * root.art.photoInset))
                height: Math.round(parent.height * (1 - 2 * root.art.photoInset))
                rotation: modelData
                color: Tokens.colorDark.text
                antialiasing: true

                GrassfieldArtwork {
                    anchors.fill: parent
                    anchors.margins: Math.max(1, Math.round(root.height * root.art.photoBorder))
                }
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
