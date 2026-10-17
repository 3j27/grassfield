import QtQuick
import Grassfield.Ui
import "LockMachine.js" as Machine

// Password entry shared by the lock screen and the authorization dialog. The text lives only in
// the TextInput: submit() hands it over once and empties the field in the same step. Copy,
// undo history and input-method prediction are off (Password echo, sensitive-data hints).
FocusScope {
    id: root

    property string placeholder: qsTr("Enter Password")
    property string accessibleName: qsTr("Password")
    property color textColor: Appearance.colors.text
    property color placeholderColor: Appearance.colors.textSecondary
    property color fillColor: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
    property color focusColor: Appearance.colors.accent
    property real radius: Tokens.radiusControl
    property int fontSize: Tokens.typographyBodySize
    // Return-arrow button inside the field, shown once something is typed (lock screen).
    property bool showSubmit: false
    // Read-only while an attempt is being checked (the placeholder then says so).
    property bool busy: false
    // Show the typed text (PAM/polkit prompts that are not secret, e.g. a user name).
    property bool reveal: false

    readonly property bool empty: input.length === 0
    // Inferred from typed letters (see LockMachine.capsLockFromKey); false until known.
    readonly property bool capsLock: priv.caps

    signal submitted(string password)
    // The user typed something (no text is passed on).
    signal edited

    implicitWidth: Tokens.lockFieldWidth
    implicitHeight: Tokens.polkitFieldHeight
    opacity: enabled ? 1 : Tokens.materialDisabledOpacity
    Accessible.role: Accessible.EditableText
    Accessible.name: root.accessibleName
    Accessible.passwordEdit: !root.reveal
    Accessible.focusable: true

    QtObject {
        id: priv
        property bool caps: false
    }

    function clear(): void {
        input.clear();
    }

    function submit(): void {
        if (!root.enabled || root.busy)
            return;
        const secret = input.text;
        input.clear();
        if (secret.length > 0)
            root.submitted(secret);
    }

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.fillColor
        border.width: input.activeFocus ? Tokens.controlFocusRing : 0
        border.color: root.focusColor
    }

    TextInput {
        id: input
        anchors {
            left: parent.left
            right: submitButton.visible ? submitButton.left : parent.right
            leftMargin: Tokens.spacingMd
            rightMargin: submitButton.visible ? Tokens.spacingXs : Tokens.spacingMd
            verticalCenter: parent.verticalCenter
        }
        focus: true
        clip: true
        readOnly: root.busy
        echoMode: root.reveal ? TextInput.Normal : TextInput.Password
        passwordCharacter: "●"
        passwordMaskDelay: 0
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | (root.reveal ? 0 : Qt.ImhHiddenText)
        color: root.textColor
        selectionColor: root.focusColor
        selectedTextColor: root.textColor
        font.family: Appearance.fontFamily
        font.pixelSize: root.fontSize
        verticalAlignment: TextInput.AlignVCenter
        Accessible.ignored: true

        onAccepted: root.submit()
        onTextEdited: root.edited()

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape && input.length > 0) {
                input.clear();
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_CapsLock) {
                priv.caps = !priv.caps;
                return;
            }
            const caps = Machine.capsLockFromKey(event.text, (event.modifiers & Qt.ShiftModifier) !== 0);
            if (caps !== null)
                priv.caps = caps;
        }
    }

    Text {
        textFormat: Text.PlainText
        anchors.fill: input
        text: root.busy ? qsTr("Checking…") : root.placeholder
        visible: root.empty
        color: root.placeholderColor
        font.family: Appearance.fontFamily
        font.pixelSize: root.fontSize
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        Accessible.ignored: true
    }

    // Return arrow (lock screen): same action as pressing Return.
    Item {
        id: submitButton
        visible: root.showSubmit && !root.empty
        width: Tokens.lockSubmitSize
        height: Tokens.lockSubmitSize
        anchors {
            right: parent.right
            rightMargin: (root.height - height) / 2
            verticalCenter: parent.verticalCenter
        }
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Unlock")
        Accessible.onPressAction: root.submit()

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Appearance.withAlpha(root.textColor, submitMouse.containsMouse ? Tokens.materialHighlightOpacity * 2 : Tokens.materialHighlightOpacity)
        }

        Icon {
            anchors.centerIn: parent
            name: "chevron-right"
            size: Tokens.menuIconSize
            color: root.textColor
        }

        MouseArea {
            id: submitMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.submit()
        }
    }
}
