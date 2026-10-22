import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services

// "About <App>": what the desktop entry offers (name, comment, generic name, id, command).
// The Version key of the desktop entry is not exposed by Quickshell, so no version is shown.
Dialog {
    id: root

    readonly property var entry: Apps.lookup(Popups.data.appId ? Popups.data.appId : "")
    readonly property string appName: entry ? entry.name : (Popups.data.appId ? Popups.data.appId : "")

    title: qsTr("About %1").arg(appName)
    sheet: true
    panelWidth: Tokens.panelAboutWidth
    onRejected: Popups.close()

    component Line: Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    content: [
        TintedIcon {
            size: Tokens.dockIconSize
            source: Quickshell.iconPath(root.entry ? root.entry.icon : "", "application-x-executable")
        },
        Line {
            visible: text !== ""
            color: Appearance.colors.text
            text: root.entry ? root.entry.comment : ""
        },
        Line {
            visible: text !== ""
            text: root.entry && root.entry.genericName !== "" ? qsTr("Type: %1").arg(root.entry.genericName) : ""
        },
        Line {
            text: qsTr("Application ID: %1").arg(Popups.data.appId ? Popups.data.appId : "")
        },
        Line {
            visible: text !== ""
            text: root.entry && root.entry.execString !== "" ? qsTr("Command: %1").arg(root.entry.execString) : ""
        }
    ]

    buttons: [
        Button {
            text: qsTr("OK")
            primary: true
            focus: true
            onClicked: Popups.close()
        }
    ]
}
