import QtQuick
import Grassfield.Ui

// Dialog frame on the material, in one of two shapes (macOS 26):
// - alert (default): an icon in a 64 frame at the top left, bold title and message left-aligned under it, capsule buttons of
//   one width filling the row;
// - sheet (sheet: true): title, message and custom content, then a full-width hairline above a 64-pt footer whose 24-pt
//   push buttons sit 20 from the right and bottom edges.
// Esc emits rejected(). Hosts focus the preferred button themselves.
FocusScope {
    id: root

    property string title: ""
    property string message: ""
    property int panelWidth: Tokens.panelAlertWidth
    // Sheet shape (see above).
    property bool sheet: false
    // Alert icon: a glyph name of the Ui icon set; none, no icon.
    property string icon: ""
    property alias content: contentColumn.data
    property alias buttons: buttonRow.data

    signal rejected

    readonly property real cornerRadius: sheet ? Tokens.radiusSheet : Tokens.radiusAlert
    readonly property real pad: sheet ? Tokens.panelSheetPadding : Tokens.spacingLg
    // An alert's icon and text sit 24 from its edges, its buttons 16; a sheet has one padding.
    readonly property real textInset: sheet ? pad : Tokens.panelAlertTextInset
    readonly property Item surface: material

    width: panelWidth
    height: sheet ? pad + column.implicitHeight + pad + Tokens.panelSheetFooterHeight : pad + column.implicitHeight + Tokens.spacingLg + buttonRow.implicitHeight + pad
    Accessible.role: Accessible.Dialog
    Accessible.name: root.title
    Accessible.description: root.message

    Keys.onEscapePressed: root.rejected()

    Material {
        id: material
        glassClass: "menu"
        anchors.fill: parent
        radius: root.cornerRadius
    }

    Column {
        id: column
        x: root.textInset
        y: root.pad
        width: root.width - 2 * root.textInset
        spacing: Tokens.spacingMd

        Item {
            visible: root.icon !== "" && !root.sheet
            width: Tokens.panelAlertIconFrame
            height: visible ? Tokens.panelAlertIconFrame : 0

            Icon {
                anchors.centerIn: parent
                size: Tokens.panelAlertIconGlyph
                name: root.icon
                color: Appearance.colors.accentInk
            }
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            visible: text !== ""
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.WordWrap
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.message
            visible: text !== ""
            color: root.sheet ? Appearance.colors.textSecondary : Appearance.colors.text
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
    }

    // Sheet footer: the hairline spans the whole sheet.
    Rectangle {
        visible: root.sheet
        x: 0
        y: root.height - Tokens.panelSheetFooterHeight
        width: root.width
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // Buttons. Alert: capsules of one width filling the row (two of them are half each), never narrower than the widest
    // label. Sheet: 24-pt push buttons of one width (a pair is equal width), right-aligned in the footer.
    Row {
        id: buttonRow
        x: root.sheet ? root.width - root.pad - width : root.pad
        y: root.sheet ? root.height - Tokens.panelSheetFooterHeight + (Tokens.panelSheetFooterHeight - height) / 2 : root.pad + column.implicitHeight + Tokens.spacingLg
        spacing: Tokens.controlAlertButtonGap

        function equalize(): void {
            const kids = buttonRow.children;
            let widest = 0;
            let count = 0;
            for (let i = 0; i < kids.length; i++) {
                if (!("capsule" in kids[i]))
                    continue;
                kids[i]["capsule"] = !root.sheet;
                kids[i]["push"] = root.sheet;
                widest = Math.max(widest, kids[i].implicitWidth);
                count++;
            }
            if (count === 0)
                return;
            const fill = root.sheet ? 0 : (root.width - 2 * root.pad - (count - 1) * buttonRow.spacing) / count;
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
