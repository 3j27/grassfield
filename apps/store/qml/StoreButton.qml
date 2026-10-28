import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui
import "Store.js" as Store

// An app's button (spec SR13): "Get", "Open" or "Installed" on a grey capsule with the label in the accent colour, bold
// (macOS 27). Installing and opening come with step 3 (ADR-0037): until then the button shows the state, disabled, and a
// tooltip says so (the pointer is read by the item around it: a disabled control gets no hover).
Item {
    id: root

    property var app: null
    property bool large: false
    readonly property string state_: Store.buttonState(root.app)
    readonly property string appName: (root.app && root.app.name) || ""

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    T.Button {
        id: button
        anchors.fill: parent
        text: Store.buttonText(root.state_)
        enabled: false
        implicitHeight: root.large ? Tokens.storeButtonLargeHeight : Tokens.storeButtonHeight
        implicitWidth: Math.max(root.large ? Tokens.storeButtonLargeMinWidth : Tokens.storeButtonMinWidth,
                                Math.ceil(label.implicitWidth + 2 * Tokens.storeButtonPadding))
        focusPolicy: Qt.StrongFocus
        Accessible.role: Accessible.Button
        Accessible.name: root.state_ === "open" ? qsTr("Open %1").arg(root.appName)
                       : root.state_ === "installed" ? qsTr("%1 is installed").arg(root.appName) : qsTr("Get %1").arg(root.appName)
        Accessible.description: tip.text

        background: Rectangle {
            radius: height / 2
            color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
        }

        contentItem: Text {
            id: label
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: button.text
            // Dimmed while disabled (the label only: the capsule keeps its grey).
            color: Appearance.withAlpha(Appearance.colors.accent, button.enabled ? 1 : Tokens.storeButtonDisabledOpacity)
            readonly property int size: root.large ? Tokens.storeButtonLargeTextSize : Tokens.storeButtonTextSize
            font.family: Appearance.fontFamily
            font.pixelSize: size
            font.weight: Tokens.typographyMenuBoldWeight
            font.letterSpacing: Appearance.tracking(size)
        }

        FocusRing {
            shapeRadius: button.height / 2
            visible: button.visualFocus
        }
    }

    HoverHandler {
        id: hover
    }

    Tooltip {
        id: tip
        text: qsTr("Installing and opening apps from the Store come in a later version.")
        shown: hover.hovered && !button.enabled
        x: Math.round((root.width - width) / 2)
        y: root.height + Tokens.spacingXs
        z: 10
    }
}
