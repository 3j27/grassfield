import QtQuick
import QtQuick.Templates as T
import QtQuick.Window
import Grassfield.Ui
import "Store.js" as Store

// An app's button (spec SR13, SR17-SR19): "Get", "Open" or "Installed" on a grey capsule with the label in the accent
// colour, bold (macOS 27); while the app's operation runs or waits in the queue, a progress ring in its place (a square in
// it while it can still leave the queue). Get asks the window for the confirmation sheet (Main.qml requestGet), Open starts
// the app (launchApp). A button that cannot act says why in its tooltip (the pointer is read by the item around it: a
// disabled control gets no hover). The backend is the window's (Main.qml): a button in a window without one shows its
// app's state, disabled.
Item {
    id: root

    property var app: null
    property bool large: false
    readonly property var host: root.Window.window
    readonly property var backend: root.host && root.host.backend !== undefined ? root.host.backend : null
    readonly property string appId: (root.app && root.app.id) || ""
    // What the button may do now (StoreBackend::actions), read again with every new snapshot.
    readonly property var actions: root.backend && root.appId !== "" && root.backend.revision >= 0 ? root.backend.actions(root.appId) : null
    readonly property var operation: root.backend ? (root.backend.operations || []).find(o => o.app === root.appId) || null : null
    readonly property string state_: Store.buttonState(root.app, root.actions, root.operation)
    readonly property string appName: (root.app && root.app.name) || ""
    readonly property string blockText: {
        if (!root.backend)
            return qsTr("Installing and opening apps work in the Store's window.");
        if (root.state_ === "get")
            return Store.getBlockText(root.actions ? root.actions.get : "source", root.app ? root.app.kind : "");
        if (root.state_ === "installed")
            return qsTr("This app has no window of its own.");
        return "";
    }
    readonly property bool canAct: root.backend !== null && !!root.host && ((root.state_ === "get" && root.blockText === "") || root.state_ === "open")

    implicitWidth: root.state_ === "progress" ? ring.implicitWidth : button.implicitWidth
    implicitHeight: button.implicitHeight

    T.Button {
        id: button
        anchors.fill: parent
        visible: root.state_ !== "progress"
        text: Store.buttonText(root.state_)
        enabled: root.canAct
        implicitHeight: root.large ? Tokens.storeButtonLargeHeight : Tokens.storeButtonHeight
        implicitWidth: Math.max(root.large ? Tokens.storeButtonLargeMinWidth : Tokens.storeButtonMinWidth,
                                Math.ceil(label.implicitWidth + 2 * Tokens.storeButtonPadding))
        focusPolicy: Qt.StrongFocus
        Accessible.role: Accessible.Button
        Accessible.name: root.state_ === "open" ? qsTr("Open %1").arg(root.appName)
                       : root.state_ === "installed" ? qsTr("%1 is installed").arg(root.appName) : qsTr("Get %1").arg(root.appName)
        Accessible.description: root.blockText

        onClicked: {
            if (root.state_ === "get")
                root.host.requestGet(root.app);
            else if (root.state_ === "open")
                root.host.launchApp(root.app);
        }

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

    // The operation's ring: its count from pacman's log once there is one, else turning; a square while it waits in the
    // queue, which takes it out (SR18). Read once a second at most by assistive technologies (the text changes with it).
    ProgressRing {
        id: ring
        anchors.verticalCenter: parent.verticalCenter
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.state_ === "progress"
        readonly property var op: root.operation
        indeterminate: !op || op.state !== "running" || op.total <= 0 || op.done <= 0
        value: op && op.total > 0 ? op.done / op.total : 0
        stop: !!op && op.state === "waiting"
        activeFocusOnTab: visible && stop
        Accessible.role: stop ? Accessible.Button : Accessible.ProgressBar
        Accessible.name: stop ? qsTr("Remove %1 from the queue").arg(root.appName) : root.appName
        Accessible.description: Store.operationText(op)
        Accessible.onPressAction: ring.remove()

        function remove(): void {
            if (ring.stop && root.backend)
                root.backend.removeWaiting(ring.op.id);
        }

        Keys.onPressed: event => {
            if (ActivationKeys.activation(event.key)) {
                ring.remove();
                event.accepted = true;
            }
        }

        TapHandler {
            enabled: ring.stop
            onTapped: ring.remove()
        }

        FocusRing {
            shapeRadius: ring.width / 2
            visible: ring.activeFocus
        }
    }

    HoverHandler {
        id: hover
    }

    Tooltip {
        id: tip
        text: root.state_ === "progress" ? Store.operationText(root.operation) : root.blockText
        shown: hover.hovered && text !== "" && (root.state_ === "progress" || !button.enabled)
        x: Math.round((root.width - width) / 2)
        y: root.height + Tokens.spacingXs
        z: 10
    }
}
