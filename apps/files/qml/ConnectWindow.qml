pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Connect to Server (⌘K, macOS 27 Finder-Connect-to-Server, FP-77): the server address with the servers connected to
// lately in its pop-up, the Favorite Servers list (+ adds the address, - removes the chosen one), Browse (the Network
// location) and Connect. Connecting opens the address in the browser window's tab through KIO; a password is asked by
// kiod's own dialog (decision F-9) and never kept by Files (NavLogic::serverUrl drops one typed in the address).
Window {
    id: root

    required property var app
    // The BrowserWindow that opened it (its tab shows the server).
    required property var browser

    property int chosen: -1
    property string errorText: ""
    readonly property url address: root.app.serverUrl(field.text)

    title: qsTr("Connect to Server")
    width: Tokens.filesConnectWindowWidth
    height: chrome.height + Tokens.filesConnectWindowHeight
    minimumWidth: Tokens.filesConnectWindowWidth
    minimumHeight: height
    maximumHeight: height
    color: Appearance.windowFill
    // ADR-0015: the window draws its own chrome (the titlebar style of grassfield-ui), as Get Info.
    property string gfChromeRole: "info"

    function connect(): void {
        if (String(root.address) === "") {
            root.errorText = qsTr("“%1” isn’t a server address Files can open (smb, sftp, ftp, webdav or nfs).").arg(field.text.trim());
            return;
        }
        root.app.noteServer(root.address);
        root.browser.tab.navigate(root.address, true);
        root.close();
    }

    function browse(): void {
        const network = root.app.standardFolder("network");
        if (String(network) !== "")
            root.browser.tab.navigate(network, true);
        root.close();
    }

    onVisibleChanged: {
        if (visible) {
            root.errorText = "";
            field.forceActiveFocus();
            field.selectAll();
        }
    }

    Shortcut {
        sequences: [StandardKey.Close, "Escape"]
        enabled: root.app.focusWindow === root
        onActivated: root.close()
    }

    UnifiedToolbar {
        id: chrome
        width: parent.width
        window: root
        style: "titlebar"
        title: root.title
        doubleClickAction: root.app.titlebarDoubleClick
        canMinimize: root.app.canMinimize
    }

    Column {
        x: Tokens.filesConnectInset
        y: chrome.height + Tokens.filesConnectInset
        width: parent.width - 2 * Tokens.filesConnectInset
        spacing: Tokens.spacingSm

        TextField {
            id: field
            width: parent.width
            accessibleName: qsTr("Server Address")
            placeholderText: qsTr("smb://server/share, sftp://user@host")
            rightPadding: Tokens.filesConnectHistoryWidth + Tokens.spacingSm
            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoPredictiveText
            onTextEdited: root.errorText = ""
            onAccepted: root.connect()

            // The servers connected to lately (Finder's chevron in the field).
            ComboBox {
                id: history
                anchors.right: parent.right
                anchors.rightMargin: Tokens.spacingXs
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.filesConnectHistoryWidth
                enabled: root.app.recentServers.length > 0
                accessibleName: qsTr("Recent Servers")
                displayText: ""
                model: root.app.recentServers.map(s => ({id: s, text: s})).concat(root.app.recentServers.length > 0 ? [{id: "", text: qsTr("Clear Recent Servers")}] : [])
                value: ""
                onPicked: id => {
                    if (id === "") {
                        root.app.clearRecentServers();
                        return;
                    }
                    field.text = id;
                    field.forceActiveFocus();
                }
            }
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.errorText !== "" ? root.errorText : qsTr("Favorite Servers:")
            color: root.errorText !== "" ? Appearance.colors.destructive : Appearance.colors.text
            wrapMode: Text.Wrap
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        // The favourite servers: striped rows, a click chooses one (its address in the field), a double click connects.
        Rectangle {
            width: parent.width
            height: Tokens.filesConnectRowHeight * Tokens.filesConnectListRows
            color: Appearance.colors.windowBackground
            border.width: Tokens.appsBorderWidth
            border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

            ListView {
                id: favorites
                anchors.fill: parent
                anchors.margins: Tokens.appsBorderWidth
                clip: true
                model: root.app.favoriteServers
                boundsBehavior: Flickable.StopAtBounds
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Favorite Servers")

                delegate: Rectangle {
                    id: favorite
                    required property string modelData
                    required property int index
                    width: favorites.width
                    height: Tokens.filesConnectRowHeight
                    color: favorite.index === root.chosen ? Appearance.highlight
                         : favorite.index % 2 === 1 ? Appearance.withAlpha(Appearance.colors.text, Tokens.filesStripeOpacity) : "transparent"
                    Accessible.role: Accessible.ListItem
                    Accessible.name: favorite.modelData
                    Accessible.selected: favorite.index === root.chosen

                    Text {
                        textFormat: Text.PlainText
                        x: Tokens.spacingSm
                        width: parent.width - 2 * x
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideMiddle
                        text: favorite.modelData
                        color: favorite.index === root.chosen ? Appearance.highlightText : Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.chosen = favorite.index;
                            field.text = favorite.modelData;
                        }
                        onDoubleClicked: {
                            field.text = favorite.modelData;
                            root.connect();
                        }
                    }
                }
            }

            // Stripes under the empty rows too (Finder).
            Repeater {
                model: Math.max(0, Tokens.filesConnectListRows - favorites.count)
                delegate: Rectangle {
                    required property int index
                    readonly property int row: favorites.count + index
                    x: Tokens.appsBorderWidth
                    y: Tokens.appsBorderWidth + row * Tokens.filesConnectRowHeight
                    width: parent.width - 2 * Tokens.appsBorderWidth
                    height: Tokens.filesConnectRowHeight
                    color: row % 2 === 1 ? Appearance.withAlpha(Appearance.colors.text, Tokens.filesStripeOpacity) : "transparent"
                }
            }
        }

        Item {
            width: parent.width
            height: connectButton.implicitHeight

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Tokens.spacingXs

                Button {
                    push: true
                    text: "+"
                    Accessible.name: qsTr("Add to Favorite Servers")
                    enabled: String(root.address) !== ""
                    onClicked: {
                        if (!root.app.addFavoriteServer(field.text))
                            root.errorText = qsTr("“%1” isn’t a server address Files can open (smb, sftp, ftp, webdav or nfs).").arg(field.text.trim());
                    }
                }

                Button {
                    push: true
                    text: "−"
                    Accessible.name: qsTr("Remove from Favorite Servers")
                    enabled: root.chosen >= 0 && root.chosen < favorites.count
                    onClicked: {
                        root.app.removeFavoriteServer(root.chosen);
                        root.chosen = -1;
                    }
                }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Tokens.spacingSm

                Button {
                    push: true
                    text: qsTr("Browse")
                    enabled: String(root.app.standardFolder("network")) !== ""
                    onClicked: root.browse()
                }

                Button {
                    id: connectButton
                    push: true
                    primary: true
                    text: qsTr("Connect")
                    enabled: field.text.trim() !== ""
                    onClicked: root.connect()
                }
            }
        }
    }
}
