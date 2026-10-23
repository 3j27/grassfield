import QtQuick
import Grassfield.Ui

// Modal sheet over the window: a title, a message, an optional text field and Cancel / confirm buttons.
// Return confirms, Esc cancels. Used for Go to Folder and for irreversible actions (Empty Trash).
Item {
    id: root

    property string title: ""
    property string message: ""
    property string confirmText: qsTr("OK")
    property bool destructive: false
    property bool withField: false
    property string placeholder: ""
    property string errorText: ""
    // function(text) returning an error message to keep the sheet open, or "" to close it.
    property var confirmHandler: null
    property Item focusBack: null
    readonly property alias fieldText: field.text

    anchors.fill: parent
    visible: false
    z: 900

    function open(): void {
        root.errorText = "";
        root.visible = true;
        if (root.withField) {
            field.forceActiveFocus();
            field.selectAll();
        } else {
            panel.forceActiveFocus();
        }
    }

    function setField(text: string): void {
        field.text = text;
    }

    function close(): void {
        root.visible = false;
        if (root.focusBack)
            root.focusBack.forceActiveFocus();
    }

    function confirm(): void {
        const cb = root.confirmHandler;
        const error = cb ? cb(field.text) : "";
        if (error && error !== "") {
            root.errorText = error;
            return;
        }
        root.close();
    }

    Rectangle {
        anchors.fill: parent
        color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity)

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: wheel => wheel.accepted = true
        }
    }

    Material {
        id: panelBack
        anchors.fill: panel
        radius: Tokens.radiusSheet
    }

    FocusScope {
        id: panel
        width: Tokens.filesSheetWidth
        height: content.implicitHeight + 2 * Tokens.spacingLg
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.spacingLg
        Accessible.role: Accessible.Dialog
        Accessible.name: root.title

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.close();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirm();
                event.accepted = true;
            }
        }

        Column {
            id: content
            x: Tokens.spacingLg
            y: Tokens.spacingLg
            width: parent.width - 2 * Tokens.spacingLg
            spacing: Tokens.spacingMd

            Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.title
                wrapMode: Text.Wrap
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyTitleSize
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Text {
                textFormat: Text.PlainText
                visible: root.message !== ""
                width: parent.width
                text: root.message
                wrapMode: Text.Wrap
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Rectangle {
                visible: root.withField
                width: parent.width
                height: Tokens.settingsSearchHeight
                radius: Tokens.radiusControl
                color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                border.width: field.activeFocus ? Tokens.controlFocusOutline : 0
                border.color: Appearance.focusRingColor

                TextInput {
                    id: field
                    TextCursor {}
                    anchors.fill: parent
                    anchors.leftMargin: Tokens.spacingSm
                    anchors.rightMargin: Tokens.spacingSm
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    focus: root.withField
                    color: Appearance.colors.text
                    selectionColor: Appearance.colors.accent
                    selectedTextColor: Appearance.colors.accentText
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    Accessible.role: Accessible.EditableText
                    Accessible.name: root.title
                    onTextChanged: root.errorText = ""

                    Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === ""
                        text: root.placeholder
                        color: Appearance.colors.textSecondary
                        font: field.font
                    }
                }
            }

            Text {
                textFormat: Text.PlainText
                visible: root.errorText !== ""
                width: parent.width
                text: root.errorText
                wrapMode: Text.Wrap
                color: Appearance.colors.danger
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.AlertMessage
                Accessible.name: root.errorText
            }

            Row {
                anchors.right: parent.right
                spacing: Tokens.spacingSm

                Button {
                    text: qsTr("Cancel")
                    onClicked: root.close()
                }

                Button {
                    text: root.confirmText
                    primary: !root.destructive
                    destructive: root.destructive
                    onClicked: root.confirm()
                }
            }
        }
    }
}
