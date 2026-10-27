import QtQuick
import Grassfield.Ui

// A printer row's picture: Grassfield's own drawing of a printer (macOS shows Apple's picture of the model), in the place and
// size macOS uses (docs/audits/settings-parity-2026-10-26.md § Printers): the body, its paper slot and the output tray.
Item {
    id: root

    // The drawing, in fractions of the picture (Grassfield's own; not a UI surface, as GrassfieldArtwork).
    readonly property var art: ({
            bodyTop: 0.22,
            bodyRadius: 0.12,
            topInset: 0.12,
            topRadius: 0.08,
            slotY: 0.55,
            slotInset: 0.16,
            slotHeight: 0.07,
            trayInset: 0.24,
            trayHeight: 0.14
        })

    implicitWidth: Tokens.settingsPrinterPictureWidth
    implicitHeight: Tokens.settingsPrinterPictureHeight
    Accessible.ignored: true

    // The paper feeder on top, a step narrower than the body.
    Rectangle {
        x: Math.round(root.width * root.art.topInset)
        width: root.width - 2 * x
        height: Math.round(root.height * root.art.bodyTop) + radius
        radius: Math.round(root.height * root.art.topRadius)
        color: Tokens.settingsDeviceBezel
    }

    Rectangle {
        y: Math.round(root.height * root.art.bodyTop)
        width: root.width
        height: root.height - y
        radius: Math.round(root.height * root.art.bodyRadius)
        color: Tokens.settingsDeviceBezel

        // The output slot.
        Rectangle {
            x: Math.round(root.width * root.art.slotInset)
            y: Math.round(root.height * root.art.slotY) - parent.y
            width: root.width - 2 * x
            height: Math.max(1, Math.round(root.height * root.art.slotHeight))
            radius: height / 2
            color: Tokens.settingsDeviceBodyShade
        }
    }

    // The output tray in front.
    Rectangle {
        x: Math.round(root.width * root.art.trayInset)
        y: root.height - height
        width: root.width - 2 * x
        height: Math.max(1, Math.round(root.height * root.art.trayHeight))
        color: Tokens.settingsDeviceBody
    }
}
