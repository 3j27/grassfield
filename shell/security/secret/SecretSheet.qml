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
        if (request.kind !== "password")
            okButton.forceActiveFocus();
        else if (request.passwordNew === true)
            newField.forceActiveFocus();
        else
            field.forceActiveFocus();
    }

    // OK: the typed password (both fields, read in one step, for a new password) or the confirmation.
    function accept(): void {
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
        root.submitNew();
    }

    // A new password's two fields hand over their text in one step (PasswordField.submit empties each); Return in either
    // takes the other one too. Nothing is kept past this call.
    function collected(which: string, password: string): void {
        if (which === "new")
            priv.first = password;
        else
            priv.second = password;
        if (priv.collecting)
            return;
        priv.collecting = true;
        if (which === "new")
            verifyField.submit();
        else
            newField.submit();
        priv.collecting = false;
        root.submitNew();
    }

    function submitNew(): void {
        const first = priv.first;
        const second = priv.second;
        priv.first = null;
        priv.second = null;
        if (first !== null && second !== null)
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

        PasswordField {
            id: field
            objectName: "secretField"
            visible: root.model.asksPassword && !root.model.passwordNew
            enabled: root.inputEnabled && root.model.canSubmit
            width: parent.width
            height: visible ? Tokens.polkitFieldHeight : 0
            placeholder: qsTr("Password")
            accessibleName: qsTr("Password")
            onSubmitted: password => root.model.submit(password, null)
        }

        PasswordField {
            id: newField
            objectName: "secretNewField"
            visible: root.model.passwordNew
            enabled: root.inputEnabled && root.model.canSubmit
            allowEmpty: true
            width: parent.width
            height: visible ? Tokens.polkitFieldHeight : 0
            placeholder: qsTr("New password")
            accessibleName: qsTr("New password")
            onSubmitted: password => root.collected("new", password)
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
            onSubmitted: password => root.collected("verify", password)
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

        // The caller's check box (gcr's choice: its label is the caller's text, capped in lines).
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

        readonly property real buttonWidth: Math.max(cancelButton.implicitWidth, okButton.implicitWidth, (root.width - 2 * root.pad - spacing) / 2)

        Button {
            id: cancelButton
            objectName: "secretCancel"
            capsule: true
            width: buttonRow.buttonWidth
            text: qsTr("Cancel")
            onClicked: root.model.cancel()
        }

        Button {
            id: okButton
            objectName: "secretOk"
            capsule: true
            primary: true
            width: buttonRow.buttonWidth
            text: qsTr("OK")
            enabled: root.model.canSubmit
            onClicked: root.accept()
        }
    }
}
