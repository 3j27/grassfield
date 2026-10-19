pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter
import "Model.js" as Model

// Expanded Wi-Fi section (CC1): scan results sorted by strength, connect to known/open networks,
// inline password for new WPA/WPA2/WPA3 personal networks (Quickshell connectWithPsk), and
// nm-connection-editor for 802.1X. SSIDs are untrusted: plain text, elided.
Column {
    id: root

    // The network waiting for a password (name; the row objects are rebuilt on every scan update).
    property string pendingName: ""
    // The network of the last join attempt: kept after submit so a late failure still reaches us.
    property string watchName: ""
    property string failure: ""
    readonly property var watchNet: {
        const name = root.watchName !== "" ? root.watchName : root.pendingName;
        for (let i = 0; i < Connectivity.networks.length; i++) {
            if (Connectivity.networks[i].name === name)
                return Connectivity.networks[i].net;
        }
        return null;
    }

    width: parent ? parent.width : implicitWidth
    spacing: Tokens.spacingXs

    // Collapsing the section or closing the panel drops the typed password and the attempt.
    onVisibleChanged: if (!visible)
        root.reset()

    Component.onDestruction: password.text = ""

    function reset(): void {
        password.text = "";
        root.pendingName = "";
        root.watchName = "";
        root.failure = "";
    }

    function failureText(reason: int): string {
        switch (Model.failReasonKey(reason)) {
        case "noSecrets":
            return qsTr("a password is required");
        case "disconnected":
            return qsTr("the connection was dropped");
        case "failed":
            return qsTr("wrong password or the network refused the connection");
        case "timeout":
            return qsTr("the network did not answer in time");
        case "lost":
            return qsTr("the network is out of range");
        default:
            return qsTr("unknown error");
        }
    }

    Connections {
        target: root.watchNet
        function onConnectionFailed(reason) {
            root.failure = root.failureText(reason);
        }
    }

    function activateRow(row: var): void {
        root.failure = "";
        root.watchName = "";
        password.text = "";
        const action = Connectivity.activate(row);
        root.pendingName = action === "password" ? row.name : "";
        if (action === "password")
            password.forceActiveFocus();
    }

    // Hands keyboard focus back to the previous item (the network row) so the hidden field does
    // not keep it (a single Esc then closes the panel).
    function releaseFocus(): void {
        const prev = password.nextItemInFocusChain(false);
        if (prev && prev !== password)
            prev.forceActiveFocus();
        else
            password.focus = false;
    }

    function cancelPassword(): void {
        root.releaseFocus();
        root.pendingName = "";
        password.text = "";
    }

    function submit(): void {
        if (password.text === "" || root.watchNet === null)
            return;
        const row = Connectivity.networks.find(r => r.name === root.pendingName);
        if (!row)
            return;
        root.watchName = root.pendingName;
        Connectivity.connectWithPassword(row, password.text);
        password.text = "";
        root.releaseFocus();
        root.pendingName = "";
    }

    Caption {
        width: parent.width
        visible: !Connectivity.wifiEnabled || Connectivity.wifiDevice === null || Connectivity.networks.length === 0
        text: Connectivity.wifiDevice === null ? qsTr("No Wi-Fi adapter")
            : !Connectivity.wifiEnabled ? qsTr("Wi-Fi is off") : qsTr("Searching for networks…")
    }

    ListView {
        id: list
        width: parent.width
        height: Math.min(contentHeight, Tokens.panelCcListMaxRows * Tokens.panelCcRowHeight)
        clip: true
        interactive: contentHeight > height
        visible: Connectivity.wifiEnabled
        model: Connectivity.networks

        delegate: ListRow {
            id: row

            required property var modelData

            width: list.width
            text: modelData.name
            iconName: modelData.strength < 0.34 ? "wifi-1" : (modelData.strength < 0.67 ? "wifi-2" : "wifi-3")
            trailingIcon: modelData.secured ? "lock" : ""
            trailing: modelData.connecting ? qsTr("Connecting") : ""
            selected: modelData.connected
            accessibleName: [modelData.name, modelData.secured ? qsTr("secured") : qsTr("open"), modelData.connected ? qsTr("connected") : ""].join(", ")
            onActivated: root.activateRow(modelData)
        }
    }

    Row {
        width: parent.width
        spacing: Tokens.spacingSm
        visible: root.pendingName !== ""

        Rectangle {
            width: parent.width - join.width - parent.spacing
            height: Tokens.panelCcRowHeight
            radius: Tokens.radiusControl
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            border.width: password.activeFocus ? Tokens.controlFocusRing : 0
            border.color: Appearance.colors.text

            TextInput {
                id: password
                TextCursor {}
                anchors.fill: parent
                anchors.leftMargin: Tokens.spacingSm
                anchors.rightMargin: Tokens.spacingSm
                verticalAlignment: TextInput.AlignVCenter
                echoMode: TextInput.Password
                clip: true
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                activeFocusOnTab: true
                Accessible.name: qsTr("Password for %1").arg(root.pendingName)
                Accessible.role: Accessible.EditableText
                onAccepted: root.submit()
                Keys.onEscapePressed: event => {
                    root.cancelPassword();
                    event.accepted = true;
                }
            }

            Caption {
                anchors.fill: parent
                anchors.leftMargin: Tokens.spacingSm
                verticalAlignment: Text.AlignVCenter
                visible: password.text === ""
                text: qsTr("Password for %1").arg(root.pendingName)
            }
        }

        NavItem {
            id: join
            width: Tokens.panelCcIconButton
            height: Tokens.panelCcRowHeight
            accessibleName: qsTr("Join network")
            ringRadius: width / 2
            onActivated: root.submit()

            Rectangle {
                anchors.centerIn: parent
                width: Tokens.panelCcIconButton
                height: width
                radius: width / 2
                color: password.text !== "" ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.menuIconSize
                    name: "checkmark"
                    color: password.text !== "" ? Appearance.colors.accentText : Appearance.colors.text
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.submit()
            }
        }
    }

    Caption {
        width: parent.width
        visible: root.failure !== ""
        text: qsTr("Could not connect: %1").arg(root.failure)
    }
}
