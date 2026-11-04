pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Setups.js" as Setups

// Privacy & Security > Disk Encryption > Change Password… (ADR-0045 OC-8, OC-0.7), as macOS asks for a password change: the
// current password, the new one, and the new one again; Change Password acts once they are typed and the two new ones match
// (Setups.passwordsReady). UDisks2 changes it on the start-up disk's LUKS device, which it finds itself (systembus.h
// disk.passphrase: the page names no device); it asks polkit first, so Grassfield's polkit sheet may come up over this one.
// The passwords live only in the three fields and in the one request: the request is built when Change Password is
// pressed and the fields are emptied right after, and on Cancel, Esc and success; nothing logs them (Backend.busAct logs the
// action's name only). A wrong current password keeps the sheet open with the service's reason and empty fields.
Sheet {
    id: root

    required property var system
    required property var backend

    readonly property string tag: "disk.act"
    readonly property bool busy: (root.backend.pendingActions ?? {})[root.tag] !== undefined

    title: qsTr("Change the start-up disk's password")
    message: qsTr("This password unlocks the start-up disk when the computer starts. Other passwords of the disk keep working.")
    confirmText: qsTr("Change Password")
    confirmEnabled: !root.busy && Setups.passwordsReady(current.text, next.text, verify.text)
    holdInput: root.busy
    // The request goes when the button is pressed; the answer closes the sheet or shows why (below).
    confirmHandler: () => {
        const started = root.system.act("disk password", {op: "disk.passphrase", old: current.text, new: next.text}, root.tag);
        root.clearFields();
        if (!started)
            return root.system.dev ? qsTr("Not applied in a dev session.") : qsTr("The password cannot be changed now.");
        return false;
    }

    function clearFields(): void {
        current.text = "";
        next.text = "";
        verify.text = "";
    }

    function openSheet(): void {
        root.clearFields();
        root.open();
        current.forceActiveFocus();
    }

    onCanceled: root.clearFields()
    onShownChanged: {
        if (!root.shown)
            root.clearFields();
    }

    Connections {
        target: root.backend

        function onFailed(tag: string, reason: string): void {
            if (tag === root.tag && root.shown)
                root.errorText = reason !== "" ? qsTr("The password was not changed: %1.").arg(reason) : qsTr("The password was not changed.");
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === root.tag && root.shown && ok)
                root.close();
        }
    }

    TextField {
        id: current
        width: parent.width
        placeholderText: qsTr("Current password")
        echoMode: TextInput.Password
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
        accessibleName: qsTr("Current password")
        onTextChanged: root.errorText = ""
    }

    TextField {
        id: next
        width: parent.width
        placeholderText: qsTr("New password")
        echoMode: TextInput.Password
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
        accessibleName: qsTr("New password")
    }

    TextField {
        id: verify
        width: parent.width
        placeholderText: qsTr("Verify")
        echoMode: TextInput.Password
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
        accessibleName: qsTr("Verify the new password")
    }

    Text {
        textFormat: Text.PlainText
        visible: verify.text !== "" && next.text !== verify.text
        width: parent.width
        wrapMode: Text.Wrap
        text: qsTr("The new passwords do not match.")
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
    }
}
