import QtQuick
import Grassfield.Ui

// One QR code of the picture (ADR-0045 OC-2, docs/specs/preview.md P13), as macOS's data detector button: a glass capsule
// (the material of the view's play control) at the bottom right of the image, a glyph, what the code is, and one push
// button. A web link names its host ("example.org", never what a user-information part would show) and opens it ("Open
// Link"); any other code (a Wi-Fi network, a contact, a one-time-password secret) is never shown on screen, only copied
// ("Copy", marked concealed for the clipboard history, as Omarchy's own QR capture does).
Item {
    id: root

    // TextInImages.parseCodes: {text, link, host}.
    property var code: ({text: "", link: false, host: ""})
    // Its place among several codes (1, 2 …), 0 when the picture holds one.
    property int number: 0
    readonly property string label: root.code.link ? root.code.host : (root.number > 0 ? qsTr("QR Code %1").arg(root.number) : qsTr("QR Code"))

    signal openRequested(string link)
    signal copyRequested(string text)

    implicitWidth: row.implicitWidth + Tokens.spacingMd + (Tokens.toolbarCapsule - Tokens.controlButtonHeight) / 2
    implicitHeight: Tokens.toolbarCapsule
    width: implicitWidth
    height: implicitHeight
    Accessible.role: Accessible.Grouping
    Accessible.name: root.code.link ? qsTr("Link %1").arg(root.label) : root.label

    Material {
        anchors.fill: parent
        radius: height / 2
    }

    Row {
        id: row
        x: Tokens.spacingMd
        anchors.verticalCenter: parent.verticalCenter
        spacing: Tokens.spacingSm

        Glyph {
            anchors.verticalCenter: parent.verticalCenter
            kind: root.code.link ? "link" : "qrcode"
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, Tokens.previewCodeChipLabelWidth)
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            text: root.label
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        // Concentric with the capsule: a push button (24 tall, a capsule) inset by the same amount at its end.
        Button {
            anchors.verticalCenter: parent.verticalCenter
            push: true
            // A click leaves the keyboard with the view (Space still closes a Glance, the arrows still browse).
            focusPolicy: Qt.NoFocus
            text: root.code.link ? qsTr("Open Link") : qsTr("Copy")
            onClicked: {
                if (root.code.link)
                    root.openRequested(root.code.text);
                else
                    root.copyRequested(root.code.text);
            }
        }
    }
}
