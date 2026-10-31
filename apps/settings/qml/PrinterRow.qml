import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// One printer of the Printers group (macOS 27): its picture, its name, a status line (a coloured dot, the state in the secondary
// colour) and a chevron; a click, Space or Return opens its sheet. Placed as measured (docs/audits/settings-parity-2026-10-26.md
// § Printers); a 1-pt separator above every row but the first.
T.AbstractButton {
    id: root

    property string status: ""
    property color dotColor: Appearance.colors.statusOn

    // Below the separator.
    readonly property real contentTop: root.Positioner.index > 0 ? 1 : 0

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    implicitHeight: root.contentTop + Tokens.settingsPrinterRowHeight
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    Accessible.role: Accessible.Button
    Accessible.name: root.text + ", " + root.status
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.clicked()

    Keys.onPressed: event => {
        if (!ActivationKeys.activation(event.key))
            return;
        if (root.visible && root.enabled)
            root.clicked();
        event.accepted = true;
    }

    background: Item {
        Rectangle {
            visible: root.contentTop > 0
            x: Tokens.settingsRowInset
            width: parent.width - 2 * Tokens.settingsRowInset
            height: Tokens.appsBorderWidth
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        // Held down: the row darkens, as macOS does while the pointer holds it.
        Rectangle {
            y: root.contentTop
            width: parent.width
            height: parent.height - y
            color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
            visible: root.down
        }

        // Keyboard focus only (never after a click).
        FocusRing {
            shapeRadius: Tokens.radiusGroup
            visible: root.visualFocus
        }
    }

    contentItem: Item {
        PrinterPicture {
            x: Tokens.settingsPrinterPictureX
            y: root.contentTop + Tokens.settingsPrinterPictureTop
            width: Tokens.settingsPrinterPictureWidth
            height: Tokens.settingsPrinterPictureHeight
        }

        Text {
            textFormat: Text.PlainText
            x: Tokens.settingsPrinterNameX
            y: root.contentTop + Tokens.settingsPrinterNameBaseline - baselineOffset
            width: chevron.x - Tokens.spacingSm - x
            elide: Text.ElideRight
            text: root.text
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Rectangle {
            x: Tokens.settingsPrinterDotX
            // Centred on the status text's capitals.
            y: statusText.y + statusText.baselineOffset - statusMetrics.capitalHeight / 2 - height / 2
            width: Tokens.settingsPrinterDotSize
            height: width
            radius: width / 2
            color: root.dotColor
        }

        FontMetrics {
            id: statusMetrics
            font: statusText.font
        }

        Text {
            id: statusText
            textFormat: Text.PlainText
            x: Tokens.settingsPrinterStatusX
            y: root.contentTop + Tokens.settingsPrinterStatusBaseline - baselineOffset
            width: chevron.x - Tokens.spacingSm - x
            elide: Text.ElideRight
            text: root.status
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        Icon {
            id: chevron
            x: root.width - width - Tokens.settingsNavChevronInset
            y: root.contentTop + (Tokens.settingsPrinterRowHeight - height) / 2
            name: "chevron-right"
            size: Tokens.settingsNavChevronSize
            color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsNavChevronOpacity)
        }
    }
}
