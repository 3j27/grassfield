pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T

// Modal sheet over its window: a title, a message, an optional text field and Cancel / confirm buttons, with more buttons
// at the leading edge when asked (macOS: "Keep Both", "Show Certificate"). Return confirms (or cancels: returnCancels),
// Esc cancels, a click outside the panel is swallowed. Used for Go to Folder, for irreversible actions (Empty Trash) and
// for KIO's questions in Files (apps/files/qml/KioSheets.qml).
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
    // Buttons at the leading edge of the button row, [{id, text}]: a click emits extra(id) and leaves the sheet open (the
    // host closes it, or changes it: "Show Certificate"). Where the row is too narrow they take a row of their own above.
    property var extraButtons: []
    // Return cancels and the cancel button is the default one: for a choice the user should not take by habit (connect
    // to a server whose identity can't be verified).
    property bool returnCancels: false
    // While shown, the keyboard stays in the sheet: whatever takes it elsewhere in the window (a view that focuses itself a
    // moment later) gives it back. For a sheet with no pop-up of its own (Files' KIO questions).
    property bool keepsKeyboard: false
    // False while the confirm button may not act yet (the Store's sheet while it checks a plan): Return does nothing either.
    property bool confirmEnabled: true
    // Content between the text and the buttons.
    default property alias body: bodySlot.data
    readonly property alias fieldText: field.text
    readonly property bool shown: root.visible

    signal accepted
    signal canceled
    signal extra(string id)

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
        // The focus goes back first: hiding may open the window's next sheet (Files' queued KIO question), which then takes it.
        if (root.focusBack)
            root.focusBack.forceActiveFocus();
        root.visible = false;
    }

    function cancel(): void {
        root.close();
        root.canceled();
    }

    function reclaimKeyboard(): void {
        if (root.visible && root.keepsKeyboard && !panel.activeFocus && root.Window.active)
            panel.forceActiveFocus();
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
        onActiveFocusChanged: {
            if (!panel.activeFocus && root.keepsKeyboard && root.visible)
                Qt.callLater(root.reclaimKeyboard);
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.cancel();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.returnCancels)
                    root.cancel();
                else
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

                Item {
                    id: buttonRow
                    // The extra buttons on a row of their own when the two groups don't fit side by side.
                    readonly property bool stacked: root.extraButtons.length > 0 && extraRow.implicitWidth + Tokens.spacingLg + mainRow.implicitWidth > width
                    width: parent.width
                    height: buttonRow.stacked ? extraRow.implicitHeight + Tokens.spacingSm + mainRow.implicitHeight : Math.max(extraRow.implicitHeight, mainRow.implicitHeight)

                    Row {
                        id: extraRow
                        anchors.left: parent.left
                        anchors.top: parent.top
                        spacing: Tokens.spacingSm

                        Repeater {
                            model: root.extraButtons

                            Button {
                                required property var modelData
                                text: modelData.text
                                onClicked: root.extra(modelData.id)
                            }
                        }
                    }

                    Row {
                        id: mainRow
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        spacing: Tokens.spacingSm

                        Button {
                            visible: root.showCancel
                            text: root.cancelText
                            primary: root.returnCancels
                            onClicked: root.cancel()
                        }

                        Button {
                            text: root.confirmText
                            primary: !root.destructive && !root.returnCancels
                            destructive: root.destructive
                            enabled: root.confirmEnabled
                            onClicked: root.confirm()
                        }
                    }
                }
            }
        }
    }
}
