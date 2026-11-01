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
    // to a server whose identity can't be verified; build and install an AUR package).
    property bool returnCancels: false
    // While shown, the keyboard stays in the sheet: whatever takes it elsewhere in the window (a view that focuses itself a
    // moment later) gives it back. For a sheet with no pop-up of its own (Files' KIO questions).
    property bool keepsKeyboard: false
    // False while the confirm button may not act yet (the Store's sheet while it checks a plan): Return does nothing either.
    property bool confirmEnabled: true
    // True while the sheet takes no click and no key (Files' KIO question that just replaced another one: the second click
    // of a double click, or a repeated Return, meant for that one must not answer this one).
    property bool holdInput: false
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
            // Not a button the user clicked last time: Return is the default button's, never that one's.
            keySink.forceActiveFocus();
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

    // The sheet's keys: true when it took the key. A key held down (its auto-repeat) answers nothing: Return held past one
    // question must not answer the next one (Grassfield's key repeat starts after 250 ms).
    function handleKey(key: int, autoRepeat: bool): bool {
        if (root.holdInput || autoRepeat)
            return key !== Qt.Key_Tab && key !== Qt.Key_Backtab;
        if (key === Qt.Key_Escape) {
            root.cancel();
            return true;
        }
        if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            if (root.returnCancels)
                root.cancel();
            else
                root.confirm();
            return true;
        }
        return false;
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
        // false: the handler answers later (it closes the sheet or sets errorText itself; Activity Monitor's Quit through
        // the shell).
        if (error === false)
            return;
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

        Keys.onPressed: event => event.accepted = root.handleKey(event.key, event.isAutoRepeat)

        // Where the keyboard is when the sheet opens without a field: Return, Esc and the rest reach the panel's handler.
        Item {
            id: keySink
            focus: true
        }

        // Swallows every click while the sheet holds its input (holdInput); above the pane.
        MouseArea {
            anchors.fill: parent
            z: 1
            enabled: root.holdInput
            acceptedButtons: Qt.AllButtons
            hoverEnabled: root.holdInput
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
                    id: titleText
                    textFormat: Text.PlainText
                    width: parent.width
                    text: root.title
                    wrapMode: Text.Wrap
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyTitleSize
                    font.weight: Tokens.typographyMenuBoldWeight
                }

                // The message, the field and the body; they scroll when the sheet would be taller than its window (a
                // long text an application gave), so the buttons stay on screen. Laid out as before when they fit.
                Flickable {
                    id: scroller
                    // What the window leaves for them: its height less the sheet's margins, padding, title, buttons and
                    // error line.
                    readonly property real room: root.height - 2 * Tokens.spacingLg - pane.topPadding - pane.bottomPadding - titleText.height - buttonRow.height - (errorLine.visible ? errorLine.height + content.spacing : 0) - 2 * content.spacing
                    width: parent.width
                    height: Math.max(0, Math.min(middle.implicitHeight, room))
                    contentWidth: width
                    contentHeight: middle.implicitHeight
                    interactive: contentHeight > height
                    clip: interactive
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}

                    Column {
                        id: middle
                        width: scroller.width
                        spacing: Tokens.spacingMd

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
                    }
                }

                Text {
                    id: errorLine
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
                                // A click leaves the keyboard where it was: Return stays the default button's.
                                focusPolicy: Qt.TabFocus
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
                            focusPolicy: Qt.TabFocus
                            onClicked: root.cancel()
                        }

                        Button {
                            text: root.confirmText
                            focusPolicy: Qt.TabFocus
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
