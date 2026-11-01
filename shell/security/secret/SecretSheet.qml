pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.security

// The secret sheet of one prompter/1 request (ADR-0035 D-9, step 9b; docs/specs/system-dialogs.md section 5): a macOS
// alert (the alert shape of the shell's dialogs, shell/overlay/Dialog.qml: the icon at the top left, a bold title, left-aligned
// text, capsule buttons of one width), never the authorization sheet (no lock or shield, never "Authentication
// required", another shape and width, another title). From the top:
//  - the requester (only the bridge fills it): its icon (an app's theme icon, else Grassfield's glyph of the role) and
//    the title naming it in Grassfield's words; an unidentified program's executable path under it, in the secondary style;
//  - the caller's own text in a framed block, introduced as such: its title, message and description, plain text in the
//    secondary style, its warning in the danger colour, each capped in lines (the bridge caps them in characters);
//  - the held notice, the field (New and Verify for a new password, with a strength meter), the caller's check box, our
//    own error line;
//  - Cancel and OK, Grassfield's labels (decision 9-16).
// A NetworkManager request (step 9c) is the macOS Wi-Fi alert: the Wi-Fi glyph, the title naming the network (its SSID a
// quoted field in Grassfield's sentence), "Requested by NetworkManager" under it, the connection's username (WPA2
// Enterprise, read-only), the password field, Show password (the typed characters shown while it is checked, never
// selectable or copyable), Cancel and Join (only for a password of an acceptable length). No caller text.
// A KIO request (step 9e) is the macOS server sheet: the globe glyph for KIO's worker (an app's icon, the warning triangle
// for an unidentified program), the title naming the server (a host name, a quoted field in Grassfield's sentence), who
// asked under it, the realm framed as the server's unverified words, the name field (read-only when the caller fixed the
// name, absent when it asks for none), the password field (no Show password), Remember this password and the line about a
// keyring without a password, Cancel and Connect (only with a password, and a name when one is asked).
// A Bluetooth pairing step (step 10) is macOS's connection request: the device's glyph, "Connection Request from “Name”",
// the device's address under it, Grassfield's sentence for the step, then the code (to compare, or to type on the device with
// how many digits were typed there), or a field for a PIN or a passkey; Cancel and Connect, Decline and Connect for an
// incoming pairing or service, Cancel alone for a code shown.
// Esc cancels. Every string from the caller is plain text (Text.PlainText), one line from the bridge, capped here in lines.
FocusScope {
    id: root

    required property SecretSheetModel model
    // Image URL of an app's icon (SecretAgent resolves model.appIcon in the icon theme), or "".
    property url appIconSource: ""
    // Set by SecretAgent for a held request (SecretSheetModel.heldNotice), else "".
    property string heldNotice: ""
    // False while SecretAgent keeps the keys on its sink: the fields and the check box take no focus and no key.
    property bool inputEnabled: true

    readonly property real cornerRadius: Tokens.radiusAlert
    readonly property Item surface: material
    readonly property real pad: Tokens.spacingLg
    // Rendered line caps of the caller's text (elided past them; assistive technologies read the whole block).
    readonly property int titleLines: 2
    readonly property int messageLines: 3
    readonly property int descriptionLines: 6
    readonly property int warningLines: 2
    readonly property int choiceLines: 2

    width: Tokens.panelAlertWidth
    height: root.pad + column.implicitHeight + Tokens.spacingLg + buttonRow.implicitHeight + root.pad
    Accessible.role: Accessible.Dialog
    Accessible.name: root.model.title
    Accessible.description: root.model.hasCallerText ? [root.model.callerIntro, root.model.callerTitle, root.model.callerMessage, root.model.callerDescription, root.model.callerWarning].filter(s => s !== "").join(" ") : ""

    Keys.onEscapePressed: root.model.cancel()

    // The first control a user types into: the (first) password field, or OK for a confirmation. Never while the input is
    // disabled (forcing the focus onto a disabled control would still move this scope's focus to it). Read from the request
    // itself: the sheet is made as the request arrives, before every binding of the model has followed it.
    function focusField(): void {
        const request = root.model.request;
        if (!root.inputEnabled || !request)
            return;
        if (request.kind === "bluetooth") {
            const mode = request.pairing.mode;
            if (mode === "pin" || mode === "passkey")
                field.forceActiveFocus();
            else if (mode === "display-pin" || mode === "display-passkey")
                cancelButton.forceActiveFocus();
            else
                okButton.forceActiveFocus();
        } else if (request.kind === "kio") {
            if (request.login.nameMode === "edit" && nameField.text === "")
                nameField.forceActiveFocus();
            else
                field.forceActiveFocus();
        } else if (request.kind === "nm")
            field.forceActiveFocus();
        else if (request.kind !== "password")
            okButton.forceActiveFocus();
        else if (request.passwordNew === true)
            newField.forceActiveFocus();
        else
            field.forceActiveFocus();
    }

    // OK (the button: a click, or Space or Return once Tab reached it): the typed password (both fields, read in one step,
    // for a new password) or the confirmation. Only here may a new password be empty (decision 9-24).
    function accept(): void {
        if (root.model.pairing) {
            // A code shown has no OK; a PIN or a passkey goes only at its length (its form is checked when sent).
            if (root.model.asksCode) {
                if (root.model.pairingReady(field.length))
                    field.submit();
            } else if (!root.model.displaysCode) {
                root.model.submit(null, null);
            }
            return;
        }
        if (root.model.server) {
            // Connect only with a password, and a name when one is asked: the fields keep what was typed otherwise.
            if (root.model.serverReady(field.length, nameField.text.length))
                field.submit();
            return;
        }
        if (root.model.network) {
            // Join only for a password of an acceptable length (and a name): the field keeps what was typed otherwise.
            if (root.model.networkReady(field.length))
                field.submit();
            return;
        }
        if (!root.model.asksPassword) {
            root.model.submit(null, null);
            return;
        }
        if (!root.model.passwordNew) {
            field.submit();
            return;
        }
        priv.collecting = true;
        newField.submit();
        verifyField.submit();
        priv.collecting = false;
        root.submitNew(true);
    }

    // Return in Verify (Return in New only moves the focus to Verify): Verify has handed over its text, New's is taken in the
    // same step (PasswordField.submit empties each). Nothing is kept past this call.
    function verifyReturned(password: string): void {
        priv.second = password;
        priv.collecting = true;
        newField.submit();
        priv.collecting = false;
        root.submitNew(false);
    }

    // `fromButton`: OK, not Return. An empty new password is sent only from OK: a stray Return never answers with one
    // (opus review of step 9b, MINOR-1).
    function submitNew(fromButton: bool): void {
        const first = priv.first;
        const second = priv.second;
        priv.first = null;
        priv.second = null;
        if (first === null || second === null)
            return;
        if (!fromButton && first === "" && second === "")
            return;
        root.model.submit(first, second);
    }

    QtObject {
        id: priv
        property bool collecting: false
        property var first: null
        property var second: null
    }

    Component.onCompleted: focusField()

    Connections {
        target: root.model

        function onClearRequested(): void {
            field.clear();
            newField.clear();
            verifyField.clear();
        }
    }

    Material {
        id: material
        anchors.fill: parent
        radius: root.cornerRadius
    }

    Column {
        id: column
        x: Tokens.panelAlertTextInset
        y: root.pad
        width: root.width - 2 * Tokens.panelAlertTextInset
        spacing: Tokens.spacingMd

        // The requester's icon: an app's own, else the glyph of its role (a key for Keyring, GnuPG and SSH, a warning
        // triangle for an unidentified program). Never a lock or a shield: those are the authorization sheet's.
        Item {
            objectName: "secretIcon"
            width: Tokens.panelAlertIconFrame
            height: Tokens.panelAlertIconFrame

            Image {
                id: appIcon
                objectName: "secretAppIcon"
                anchors.fill: parent
                source: root.appIconSource
                sourceSize: Qt.size(Tokens.panelAlertIconFrame * 2, Tokens.panelAlertIconFrame * 2)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                visible: status === Image.Ready
                Accessible.ignored: true
            }

            Icon {
                objectName: "secretGlyph"
                anchors.centerIn: parent
                visible: !appIcon.visible
                name: root.model.glyph
                size: Tokens.panelAlertIconGlyph
                // The text colour, as the authorization sheet's glyph: legible on the glass at every transparency (gate A2).
                color: Appearance.colors.text
            }
        }

        // The title: who asks (the bridge's requester, in Grassfield's words) and for what. Never the caller's text.
        Text {
            objectName: "secretTitle"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.Wrap
            maximumLineCount: root.titleLines
            elide: Text.ElideRight
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        // Who asked a NetworkManager request: the program the bridge checked the call came from.
        Text {
            objectName: "secretRequester"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.requesterDetail
            visible: text !== ""
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.Wrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // An unidentified program's executable, as the bridge read it from the caller's pidfd.
        Text {
            objectName: "secretPath"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.requesterPath
            visible: text !== ""
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.WrapAnywhere
            maximumLineCount: root.titleLines
            elide: Text.ElideMiddle
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // A pairing step: what is asked, in Grassfield's words (the device's name is only in the title).
        Text {
            objectName: "secretPairingMessage"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.pairingMessage
            visible: text !== ""
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            wrapMode: Text.Wrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // The code to compare, or to type on the device: large, its digits apart.
        Text {
            objectName: "secretPairingCode"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.pairingCode
            visible: text !== ""
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.text
            font.family: Tokens.typographyMonoFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
            font.letterSpacing: Tokens.spacingXs
            Accessible.role: Accessible.StaticText
            Accessible.name: text.split("").join(" ")
        }

        // How many digits were typed on the device (a passkey shown; updated without touching the keyboard).
        Text {
            objectName: "secretPairingProgress"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.pairingProgress
            visible: text !== ""
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.Wrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // A service the sheet cannot name: its UUID, as bluetoothd gave it.
        Text {
            objectName: "secretPairingUuid"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.serviceUuid
            visible: text !== ""
            color: Appearance.colors.textSecondary
            font.family: Tokens.typographyMonoFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.WrapAnywhere
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // The caller's text, framed and introduced as the caller's (spec SC3, SC3b): nothing in the sheet vouches for it.
        Rectangle {
            objectName: "secretCallerBlock"
            width: parent.width
            height: callerColumn.implicitHeight + 2 * Tokens.spacingSm
            visible: root.model.hasCallerText
            radius: Tokens.radiusControl
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

            Column {
                id: callerColumn
                x: Tokens.spacingSm
                y: Tokens.spacingSm
                width: parent.width - 2 * Tokens.spacingSm
                spacing: Tokens.spacingXs

                Text {
                    objectName: "secretCallerIntro"
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.model.callerIntro
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.italic: true
                    wrapMode: Text.Wrap
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }

                Repeater {
                    model: [{key: "title", text: root.model.callerTitle, lines: root.titleLines}, {key: "message", text: root.model.callerMessage, lines: root.messageLines}, {key: "description", text: root.model.callerDescription, lines: root.descriptionLines}]

                    Text {
                        required property var modelData
                        objectName: "secretCaller_" + modelData.key
                        width: callerColumn.width
                        visible: text !== ""
                        textFormat: Text.PlainText
                        text: modelData.text
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                        font.weight: Tokens.typographySmallWeight
                        wrapMode: Text.Wrap
                        maximumLineCount: modelData.lines
                        elide: Text.ElideRight
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }
                }

                Text {
                    objectName: "secretCaller_warning"
                    width: parent.width
                    visible: text !== ""
                    textFormat: Text.PlainText
                    text: root.model.callerWarning
                    color: Appearance.colors.danger
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    wrapMode: Text.Wrap
                    maximumLineCount: root.warningLines
                    elide: Text.ElideRight
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
            }
        }

        Text {
            objectName: "secretHeldNotice"
            width: parent.width
            textFormat: Text.PlainText
            text: root.heldNotice
            visible: root.heldNotice !== ""
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.Wrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // A WPA2 Enterprise network's username, as the connection holds it: read-only, since NetworkManager keeps only
        // secrets from an agent's reply (opus review of step 9c, MAJOR).
        Text {
            objectName: "secretIdentity"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.showsIdentity ? qsTr("Username: %1").arg(root.model.identity) : ""
            visible: text !== ""
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 2
            elide: Text.ElideRight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // A server's name (step 9e): not a secret (the name the caller gave, at first), so a plain field; KIO's client takes
        // it back from the reply, unlike NetworkManager. Read-only when the caller fixed the name.
        TextField {
            id: nameField
            objectName: "secretName"
            visible: root.model.asksName
            enabled: root.inputEnabled && root.model.canSubmit
            readOnly: !visible || !enabled || root.model.nameReadOnly
            width: parent.width
            height: visible ? implicitHeight : 0
            text: root.model.loginName
            placeholderText: qsTr("Name")
            accessibleName: qsTr("Name")
            inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
            onTextEdited: root.model.loginName = text
            onAccepted: field.forceActiveFocus()
        }

        PasswordField {
            id: field
            objectName: "secretField"
            visible: root.model.asksPassword && !root.model.passwordNew
            enabled: root.inputEnabled && root.model.canSubmit
            width: parent.width
            height: visible ? Tokens.polkitFieldHeight : 0
            placeholder: root.model.pairingMode === "pin" ? qsTr("PIN") : root.model.pairingMode === "passkey" ? qsTr("Code") : qsTr("Password")
            accessibleName: root.model.pairingMode === "pin" ? qsTr("PIN") : root.model.pairingMode === "passkey" ? qsTr("Code") : qsTr("Password")
            // Show password (a network's only): the characters as typed, never anywhere else than in this field.
            reveal: root.model.network && root.model.showPassword
            // Shown, it is never selectable or copyable (opus review of step 9c, MINOR): not to the clipboard, not to the
            // primary selection. A server's field is never shown (no Show password), so the guard only waits there.
            copyable: false
            // A network's Return goes through Join's rule, a server's and a pairing code's through Connect's (accept): a password
            // too short, a missing name, or a code of the wrong length keeps what was typed.
            submitOnReturn: !root.model.network && !root.model.server && !root.model.asksCode
            onReturnPressed: root.accept()
            onSubmitted: password => root.model.submit(password, null)
        }

        PasswordField {
            id: newField
            objectName: "secretNewField"
            visible: root.model.passwordNew
            enabled: root.inputEnabled && root.model.canSubmit
            allowEmpty: true
            // Return moves on to Verify and hands nothing over (OK takes both fields).
            submitOnReturn: false
            width: parent.width
            height: visible ? Tokens.polkitFieldHeight : 0
            placeholder: qsTr("New password")
            accessibleName: qsTr("New password")
            onReturnPressed: verifyField.forceActiveFocus()
            onSubmitted: password => {
                if (priv.collecting)
                    priv.first = password;
            }
        }

        PasswordField {
            id: verifyField
            objectName: "secretVerifyField"
            visible: root.model.passwordNew
            enabled: root.inputEnabled && root.model.canSubmit
            allowEmpty: true
            width: parent.width
            height: visible ? Tokens.polkitFieldHeight : 0
            placeholder: qsTr("Verify")
            accessibleName: qsTr("Verify the new password")
            onSubmitted: password => {
                if (priv.collecting)
                    priv.second = password;
                else
                    root.verifyReturned(password);
            }
        }

        // The new password's strength, from its length only (SecretSheetModel.strengthOf).
        Column {
            id: strengthMeter
            objectName: "secretStrength"
            readonly property int level: root.model.strengthOf(newField.length)
            visible: root.model.showsStrength
            width: parent.width
            spacing: Tokens.spacingXs

            ProgressBar {
                width: parent.width
                from: 0
                to: 3
                value: strengthMeter.level
                accessibleName: strengthLabel.text
            }

            Text {
                id: strengthLabel
                width: parent.width
                textFormat: Text.PlainText
                text: [qsTr("Password strength: none"), qsTr("Password strength: weak"), qsTr("Password strength: fair"), qsTr("Password strength: strong")][strengthMeter.level]
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                wrapMode: Text.Wrap
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        // Show password (a network's): the field shows the characters as typed while it is checked.
        CheckBox {
            id: showPasswordBox
            objectName: "secretShowPassword"
            visible: root.model.network
            enabled: root.inputEnabled && root.model.canSubmit
            width: parent.width
            text: qsTr("Show password")
            checked: root.model.showPassword
            onToggled: root.model.showPassword = checked
        }

        // The caller's check box (gcr's choice: its label is the caller's text, capped in lines), or a server's Remember this
        // password (Grassfield's label).
        CheckBox {
            id: choiceBox
            objectName: "secretChoice"
            visible: root.model.hasChoice
            enabled: root.inputEnabled && root.model.canSubmit
            width: parent.width
            text: root.model.choiceLabel
            checked: root.model.choice
            onToggled: root.model.choice = checked
        }

        // The keyring that would keep a remembered password has no password (decision 9-45): said under Remember, whether or
        // not it is checked.
        Text {
            objectName: "secretKeyringNotice"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.keyringNotice
            visible: text !== ""
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.Wrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            objectName: "secretError"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.error
            visible: text !== ""
            color: Appearance.colors.danger
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.Wrap
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
    }

    // Capsules of one width filling the row, as an alert's (Dialog.qml). Grassfield's labels, never the caller's.
    Row {
        id: buttonRow
        x: root.pad
        y: root.pad + column.implicitHeight + Tokens.spacingLg
        spacing: Tokens.controlAlertButtonGap

        // One button (a code shown: Cancel alone) fills the row.
        readonly property real buttonWidth: okButton.visible ? Math.max(cancelButton.implicitWidth, okButton.implicitWidth, (root.width - 2 * root.pad - spacing) / 2) : root.width - 2 * root.pad

        Button {
            id: cancelButton
            objectName: "secretCancel"
            capsule: true
            width: buttonRow.buttonWidth
            text: root.model.authorizes ? qsTr("Decline") : qsTr("Cancel")
            onClicked: root.model.cancel()
        }

        Button {
            id: okButton
            objectName: "secretOk"
            capsule: true
            primary: true
            width: buttonRow.buttonWidth
            text: root.model.network ? qsTr("Join") : root.model.server || root.model.pairing ? qsTr("Connect") : qsTr("OK")
            // A code shown has no OK: only Cancel (decision 10-6).
            visible: !root.model.displaysCode
            enabled: root.model.canSubmit && (root.model.network ? root.model.networkReady(field.length) : !root.model.server || root.model.serverReady(field.length, nameField.text.length)) && (!root.model.asksCode || root.model.pairingReady(field.length))
            onClicked: root.accept()
        }
    }
}
