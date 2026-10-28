import QtQuick
import QtQuick.Templates as T

// Modal sheet over its window: a title, a message, an optional text field and Cancel / confirm buttons. Return confirms,
// Esc cancels, a click outside the panel is swallowed. Used for Go to Folder and for irreversible actions (Empty Trash).
// Declare it as a child of the window's content; it fills it. The panel is a QtQuick.Templates Pane on the frosted material.
Item {
    id: root

    property string title: ""
    property string message: ""
    property string confirmText: qsTr("OK")
    property bool destructive: false
    property bool withField: false
    property string placeholder: ""
    // The field hides what is typed (a password); the host may show it again (a "Show password" check box).
    property bool fieldPassword: false
    property string errorText: ""
    // function(text) returning an error message to keep the sheet open, or "" to close it.
    property var confirmHandler: null
    property Item focusBack: null
    // False: only the confirm button (an options sheet whose changes apply at once, macOS "Done").
    property bool showCancel: true
    // The cancel button's text (Displays' countdown sheet says "Revert").
    property string cancelText: qsTr("Cancel")
    // False while the confirm button may not act yet (the Store's sheet while it checks a plan): Return does nothing either.
    property bool confirmEnabled: true
    // Content between the text and the buttons.
    default property alias body: bodySlot.data
    readonly property alias fieldText: field.text
    readonly property bool shown: root.visible

    signal accepted
    signal canceled

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

    function cancel(): void {
        root.close();
        root.canceled();
    }

    function confirm(): void {
        if (!root.confirmEnabled)
            return;
        const cb = root.confirmHandler;
        const error = cb ? cb(field.text) : "";
        if (error && error !== "") {
            root.errorText = error;
            return;
        }
        root.close();
        root.accepted();
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

    FocusScope {
        id: panel
        width: Tokens.controlSheetWidth
        height: pane.implicitHeight
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.spacingLg
        Accessible.role: Accessible.Dialog
        Accessible.name: root.title

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.cancel();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.confirm();
                event.accepted = true;
            }
        }

        T.Pane {
            id: pane
            anchors.fill: parent
            padding: Tokens.spacingLg
            implicitHeight: content.implicitHeight + topPadding + bottomPadding

            background: Material {
                radius: Tokens.radiusSheet
            }

            contentItem: Column {
                id: content
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

                TextField {
                    id: field
                    visible: root.withField
                    width: parent.width
                    focus: root.withField
                    placeholderText: root.placeholder
                    echoMode: root.fieldPassword ? TextInput.Password : TextInput.Normal
                    // A password (Wi-Fi's join): the input method neither learns, stores nor predicts it (GF-118).
                    inputMethodHints: root.fieldPassword ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText : Qt.ImhNone
                    accessibleName: root.title
                    onTextChanged: root.errorText = ""
                }

                Column {
                    id: bodySlot
                    width: parent.width
                    spacing: Tokens.spacingMd
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
                        visible: root.showCancel
                        text: root.cancelText
                        onClicked: root.cancel()
                    }

                    Button {
                        text: root.confirmText
                        primary: !root.destructive
                        destructive: root.destructive
                        enabled: root.confirmEnabled
                        onClicked: root.confirm()
                    }
                }
            }
        }
    }
}
