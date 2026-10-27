pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.security

// Authorization sheet for one polkit request: lock icon, the request message, action ID,
// identity, password field, Cancel / Allow (default). Every string that comes from the
// requester or polkit is rendered as plain text (no rich text, no remote images), flattened to
// one line by the model and capped in rendered lines here, so the sheet has a bounded height and
// the action ID and the buttons always stay visible. Esc cancels.
FocusScope {
    id: root

    required property AuthDialogModel model
    // Image URL of the action's icon (AuthAgent resolves model.iconName in the icon theme), or "".
    property url appIconSource: ""
    // Set by AuthAgent for a request that arrived while the session was locked (AuthDialogModel.heldNotice), else "".
    property string heldNotice: ""
    // False while AuthAgent keeps the keys on its sink: the field and the identity rows take no focus and no key, whatever
    // focuses them and whether or not the window has the keyboard yet (check of c1ca44f, M2). Cancel stays clickable.
    property bool inputEnabled: true

    readonly property real cornerRadius: Tokens.radiusDialog
    readonly property Item surface: material
    // Rendered line caps of untrusted text (elided past them) and visible identity rows.
    readonly property int messageLines: 4
    readonly property int storeLines: 8
    readonly property int detailLines: 2
    readonly property int identityRows: 4

    width: Tokens.panelDialogWidth
    height: column.implicitHeight + 2 * Tokens.spacingLg
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Authentication required")
    Accessible.description: root.model.message

    Keys.onEscapePressed: root.model.cancel()

    // Not while the input is disabled: forcing the focus onto a disabled field would still move this scope's focus to it.
    function focusField(): void {
        if (root.inputEnabled)
            field.forceActiveFocus();
    }

    Component.onCompleted: focusField()

    Connections {
        target: root.model

        function onClearRequested(): void {
            field.clear();
        }

        function onFailed(): void {
            shakeAnimation.restart();
            root.focusField();
        }
    }

    Material {
        id: material
        anchors.fill: parent
        radius: root.cornerRadius
    }

    Column {
        id: column
        x: Tokens.spacingLg
        y: Tokens.spacingLg
        width: root.width - 2 * Tokens.spacingLg
        spacing: Tokens.spacingMd

        // The action's icon with a lock badge (macOS style), when the action's polkit definition names a theme icon that
        // exists; else the lock alone. It is not the icon of the program that asked (polkit does not give it here).
        Item {
            objectName: "polkitIcon"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.polkitIconSize
            height: Tokens.polkitIconSize

            Image {
                id: appIcon
                objectName: "polkitAppIcon"
                anchors.fill: parent
                source: root.appIconSource
                sourceSize: Qt.size(Tokens.polkitIconSize * 2, Tokens.polkitIconSize * 2)
                fillMode: Image.PreserveAspectFit
                // Off the GUI thread (review of 100692f): a file swapped after its check can stall only the loader.
                asynchronous: true
                visible: status === Image.Ready
                Accessible.ignored: true
            }

            Icon {
                objectName: "polkitLock"
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                name: "lock"
                size: appIcon.visible ? Tokens.dockBadgeSize : Tokens.polkitIconSize
                color: Appearance.colors.text
            }
        }

        Text {
            objectName: "polkitMessage"
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.message !== "" ? root.model.message : qsTr("An application wants to make changes.")
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.Wrap
            // Grassfield Store's request names its packages in plain words (SD2): more lines for a long list.
            maximumLineCount: root.model.storeRequest ? root.storeLines : root.messageLines
            elide: Text.ElideRight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            objectName: "polkitHeldNotice"
            width: parent.width
            textFormat: Text.PlainText
            text: root.heldNotice
            visible: root.heldNotice !== ""
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.Wrap
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: qsTr("Enter your password to allow this.")
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographySmallWeight
            wrapMode: Text.Wrap
        }

        // Details provided by polkit: the action being authorized.
        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: qsTr("Action: %1").arg(root.model.actionId)
            visible: root.model.actionId !== ""
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.WrapAnywhere
            maximumLineCount: root.detailLines
            elide: Text.ElideRight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // The program polkit will run, when the model reads it from the request (Grassfield Store's helper, SD2): the plain
        // words above name what it does, this line what does it.
        Text {
            objectName: "polkitProgram"
            width: parent.width
            textFormat: Text.PlainText
            text: qsTr("Program: %1").arg(root.model.program)
            visible: root.model.program !== ""
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.WrapAnywhere
            maximumLineCount: root.detailLines
            elide: Text.ElideRight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // Identity: a label for one, a choice for several (e.g. several admin users).
        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: qsTr("User: %1").arg(root.model.identityName)
            visible: root.model.identities.length <= 1 && root.model.identityName !== ""
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            elide: Text.ElideMiddle
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        // Identity names come from polkit/passwd: plain-text rows, not rich-text buttons. At most
        // identityRows are visible; more scroll.
        Flickable {
            id: identityList
            enabled: root.inputEnabled
            width: parent.width
            height: Math.min(identityColumn.implicitHeight, root.identityRows * Tokens.menuItemHeight)
            visible: root.model.identities.length > 1
            clip: true
            contentHeight: identityColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
                id: identityColumn
                width: identityList.width

                Repeater {
                    model: root.model.identities.length > 1 ? root.model.identities : []

                    Item {
                        id: identityRow

                        required property var modelData
                        readonly property bool selected: modelData === root.model.selectedIdentity

                        width: parent.width
                        height: Tokens.menuItemHeight
                        activeFocusOnTab: true
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: qsTr("Authenticate as %1").arg(identityName.text)
                        Accessible.checkable: true
                        Accessible.checked: selected
                        Accessible.onPressAction: root.model.selectIdentity(modelData)
                        Keys.onSpacePressed: root.model.selectIdentity(modelData)
                        // Keep the focused row inside the visible rows.
                        onActiveFocusChanged: {
                            if (activeFocus)
                                identityList.contentY = Math.max(0, Math.min(y, identityList.contentHeight - identityList.height));
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: Tokens.radiusControl
                            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                            visible: identityRow.selected
                            border.width: identityRow.activeFocus ? Tokens.controlFocusRing : 0
                            border.color: Appearance.colors.accent
                        }

                        Icon {
                            id: check
                            x: Tokens.spacingSm
                            anchors.verticalCenter: parent.verticalCenter
                            name: "checkmark"
                            size: Tokens.menuIconSize
                            color: Appearance.colors.text
                            visible: identityRow.selected
                        }

                        Text {
                            id: identityName
                            anchors {
                                left: check.right
                                leftMargin: Tokens.spacingSm
                                right: parent.right
                                rightMargin: Tokens.spacingSm
                                verticalCenter: parent.verticalCenter
                            }
                            textFormat: Text.PlainText
                            text: root.model.identityLabel(identityRow.modelData)
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            elide: Text.ElideMiddle
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.model.selectIdentity(identityRow.modelData)
                        }
                    }
                }
            }
        }

        Item {
            id: fieldHolder
            width: parent.width
            height: Tokens.polkitFieldHeight

            PasswordField {
                id: field
                enabled: root.inputEnabled
                x: 0
                width: parent.width
                height: parent.height
                placeholder: root.model.prompt !== "" ? root.model.prompt : qsTr("Password")
                accessibleName: placeholder
                reveal: root.model.responseVisible
                busy: root.model.submitted
                onSubmitted: password => root.model.submit(password)
            }

            SequentialAnimation {
                id: shakeAnimation

                readonly property int leg: Appearance.reduceMotion ? 0 : Tokens.lockShakeDuration

                NumberAnimation {
                    target: field
                    property: "x"
                    to: -Tokens.lockShakeDistance
                    duration: shakeAnimation.leg / 2
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: Tokens.lockShakeDistance
                    duration: shakeAnimation.leg
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: 0
                    duration: shakeAnimation.leg / 2
                }
            }
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.model.feedback
            visible: text !== ""
            color: root.model.feedbackIsError ? Appearance.colors.danger : Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.Wrap
            maximumLineCount: root.detailLines
            elide: Text.ElideRight
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Row {
            anchors.right: parent.right
            spacing: Tokens.spacingSm

            Button {
                text: qsTr("Cancel")
                onClicked: root.model.cancel()
            }

            Button {
                text: qsTr("Allow")
                primary: true
                enabled: root.model.canSubmit
                onClicked: field.submit()
            }
        }
    }
}
