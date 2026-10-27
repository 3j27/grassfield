pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// Updates (spec SR24, read only in step 2): what Software Update found (software-update.json, ADR-0033): the installed apps
// the next system update upgrades, each marked "Updates with the system", the count of the other packages, and the
// Grassfield and Omarchy releases. Updating stays Software Update's (step 4 adds Update All… and Check Now here).
ScrollPage {
    id: root

    property var updates: ({state: "unknown"})

    signal opened(string id)

    readonly property var apps: root.updates.apps || []

    title: qsTr("Updates")
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    Text {
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        visible: text !== ""
        textFormat: Text.PlainText
        text: Store.updatesStatus(root.updates)
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBodySize
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    // The releases Software Update names.
    Repeater {
        model: [{name: qsTr("Grassfield"), release: root.updates.grassfield}, {name: qsTr("Omarchy"), release: root.updates.omarchy}]
            .filter(r => r.release && r.release.available)

        delegate: Text {
            required property var modelData
            width: root.contentWidth
            textFormat: Text.PlainText
            text: qsTr("%1 %2 is available (installed: %3).").arg(modelData.name).arg(modelData.release.available).arg(modelData.release.installed || "?")
            wrapMode: Text.Wrap
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBodySize
        }
    }

    Column {
        width: root.contentWidth
        visible: root.apps.length > 0
        spacing: 0

        Repeater {
            model: root.apps

            delegate: Item {
                id: entry
                required property var modelData
                required property int index
                width: root.contentWidth
                implicitHeight: lockup.implicitHeight

                AppLockup {
                    id: lockup
                    width: parent.width
                    app: entry.modelData
                    showButton: false
                    separator: entry.index < root.apps.length - 1
                    onOpened: id => root.opened(id)
                }

                Column {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        anchors.right: parent.right
                        textFormat: Text.PlainText
                        text: qsTr("Updates with the system")
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.storeBadgeSize
                    }

                    Text {
                        anchors.right: parent.right
                        textFormat: Text.PlainText
                        text: qsTr("%1 → %2").arg(entry.modelData.from).arg(entry.modelData.to)
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.storeBadgeSize
                    }
                }
            }
        }
    }

    Text {
        width: root.contentWidth
        visible: (root.updates.otherCount || 0) > 0
        textFormat: Text.PlainText
        text: root.apps.length > 0 ? qsTr("Other system packages: %1").arg(root.updates.otherCount) : qsTr("System packages: %1").arg(root.updates.otherCount)
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBodySize
    }

    Text {
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        textFormat: Text.PlainText
        text: qsTr("Apps from the repositories update with the whole system, in Software Update (Settings > General).")
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBadgeSize
    }
}
