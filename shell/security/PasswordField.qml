import QtQuick
import Grassfield.Ui
import "LockMachine.js" as Machine

// Password entry shared by the lock screen and the authorization dialog. The text lives only in
// the TextInput: submit() hands it over once and empties the field in the same step. Copy,
// undo history and input-method prediction are off (Password echo, sensitive-data hints). A field
// shown as typed (reveal) keeps Qt's normal-echo behaviour, copy included, unless `copyable` is false
// (a secret sheet's Show password: opus review of step 9c).
FocusScope {
    id: root

    property string placeholder: qsTr("Enter Password")
    property string accessibleName: qsTr("Password")
    property color textColor: Appearance.colors.text
    property color placeholderColor: Appearance.colors.textSecondary
    property color fillColor: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
    // The shared keyboard focus ring (FocusRing: outside the field, as on every other field) while the field has the focus.
    // Off on the lock, whose field always has the focus: a plain frosted capsule, as macOS draws it (UI audit 2026-11-05 U23).
    // Display only: it never changes the field's geometry, focus or input.
    property bool focusRing: true
    // Where the placeholder (and "Checking…") sits: centred in the lock's capsule, as macOS; leading elsewhere.
    property int placeholderAlignment: Text.AlignLeft
    // Selection (Shift+arrows, Ctrl+A) as in every other text field of the shell and on macOS, where it follows the
    // accent (highlight) colour: the accent behind the dots, drawn in the text colour made for it (gate A2).
    property color selectionColor: Appearance.colors.accent
    property color selectedTextColor: Appearance.colors.accentText
    property real radius: Tokens.radiusControl
    property int fontSize: Tokens.typographyBodySize
    // Return-arrow button inside the field, shown once something is typed (lock screen).
    property bool showSubmit: false
    // Read-only while an attempt is being checked (the placeholder then says so).
    property bool busy: false
    // Show the typed text (PAM/polkit prompts that are not secret, e.g. a user name; a secret sheet's Show password).
    property bool reveal: false
    // False: while the text is shown (reveal), nothing of it can be selected, copied or cut (keys or mouse), so neither the
    // clipboard nor the primary selection ever gets it; hidden, Qt's password echo copies nothing anyway. True (the default)
    // keeps the TextInput's own behaviour (the polkit sheet's visible answers).
    property bool copyable: true
    readonly property bool guarded: root.reveal && !root.copyable
    // An empty field is handed over too (a secret sheet's new password: gcr's caller then offers to store passwords
    // unencrypted, ADR-0035 D-9). Off for the lock and the authorization sheet: an empty field sends nothing there.
    property bool allowEmpty: false
    // Return hands the text over (submit). False: Return only emits returnPressed and the text stays (a secret sheet's New
    // field, whose Return moves on to Verify: opus review of step 9b, MINOR-1). True for the lock and the authorization
    // sheet.
    property bool submitOnReturn: true

    readonly property bool empty: input.length === 0
    // How many characters are typed (a new password's strength meter reads only this, never the text).
    readonly property int length: input.length
    // Inferred from typed letters (see LockMachine.capsLockFromKey); false until known.
    readonly property bool capsLock: priv.caps

    signal submitted(string password)
    // Return was pressed while submitOnReturn is false (nothing is handed over).
    signal returnPressed
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

    onGuardedChanged: if (guarded)
        input.deselect()

    function clear(): void {
        input.clear();
    }

    function submit(): void {
        if (!root.enabled || root.busy)
            return;
        const secret = input.text;
        input.clear();
        if (secret.length > 0 || root.allowEmpty)
            root.submitted(secret);
    }

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.fillColor
    }

    FocusRing {
        shapeRadius: root.radius
        visible: root.focusRing && input.activeFocus
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
        // Guarded: no mouse selection (on Wayland a mouse selection fills the primary selection), and a selection made
        // while hidden is dropped as the text shows.
        selectByMouse: !root.guarded
        passwordCharacter: "●"
        passwordMaskDelay: 0
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | (root.reveal ? 0 : Qt.ImhHiddenText)
        color: root.textColor
        selectionColor: root.selectionColor
        selectedTextColor: root.selectedTextColor
        font.family: Appearance.fontFamily
        font.pixelSize: root.fontSize
        verticalAlignment: TextInput.AlignVCenter
        Accessible.ignored: true

        onAccepted: root.submitOnReturn ? root.submit() : root.returnPressed()
        onTextEdited: root.edited()
        onSelectedTextChanged: if (root.guarded && input.selectedText.length > 0)
            input.deselect()

        Keys.onPressed: event => {
            // Guarded: Copy, Cut, Select All and every Shift selection key stop here, before the TextInput sees them.
            if (root.guarded && (event.matches(StandardKey.Copy) || event.matches(StandardKey.Cut) || event.matches(StandardKey.SelectAll)
                    || ((event.modifiers & Qt.ShiftModifier) !== 0 && [Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down, Qt.Key_Home, Qt.Key_End, Qt.Key_PageUp, Qt.Key_PageDown].indexOf(event.key) >= 0))) {
                event.accepted = true;
                return;
            }
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
        horizontalAlignment: root.placeholderAlignment
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
