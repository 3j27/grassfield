import QtQuick
import Grassfield.Ui

// Dialog frame on the material: title, optional message, custom content, button row.
// Esc emits rejected(). Hosts focus the preferred button themselves.
FocusScope {
    id: root

    property string title: ""
    property string message: ""
    property int panelWidth: Tokens.panelAlertWidth
    property alias content: contentColumn.data
    property alias buttons: buttonRow.data

    signal rejected

    readonly property real cornerRadius: Tokens.radiusAlert
    readonly property Item surface: material

    width: panelWidth
    height: column.implicitHeight + 2 * Tokens.spacingLg
    Accessible.role: Accessible.Dialog
    Accessible.name: root.title
    Accessible.description: root.message

    Keys.onEscapePressed: root.rejected()

    Material {
        id: material
        anchors.fill: parent
        radius: root.cornerRadius
    }

    Column {
        id: column
        x: Tokens.spacingLg
        y: Tokens.spacingLg
        width: root.width - 2 * Tokens.spacingLg
        spacing: Tokens.spacingMd

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            visible: text !== ""
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.WordWrap
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.message
            visible: text !== ""
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographySmallWeight
            wrapMode: Text.WordWrap
        }

        Column {
            id: contentColumn
            width: parent.width
            spacing: Tokens.spacingSm
        }

        // Alert buttons: capsules of one width, filling the row (two of them are half each), never narrower than the widest label.
        Row {
            id: buttonRow
            anchors.right: parent.right
            spacing: Tokens.controlAlertButtonGap

            function equalize(): void {
                const kids = buttonRow.children;
                let widest = 0;
                let count = 0;
                for (let i = 0; i < kids.length; i++) {
                    if (!("capsule" in kids[i]))
                        continue;
                    kids[i]["capsule"] = true;
                    widest = Math.max(widest, kids[i].implicitWidth);
                    count++;
                }
                if (count === 0)
                    return;
                const fill = (column.width - (count - 1) * buttonRow.spacing) / count;
                const wanted = Math.max(widest, fill);
                for (let i = 0; i < kids.length; i++) {
                    if ("capsule" in kids[i])
                        kids[i].width = wanted;
                }
            }

            Component.onCompleted: equalize()
            onChildrenChanged: Qt.callLater(equalize)
        }
    }
}
