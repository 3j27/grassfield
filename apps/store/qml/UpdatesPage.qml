pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// Updates (spec SR24, SR25; ADR-0037 d, step 4).
//   - The state line (Store.updatesStatus) and Check Now: the shell's check (ADR-0033 d.7), pacman -Qu and Flathub's.
//   - The system: what Software Update found (software-update.json): the Grassfield and Omarchy releases, the installed apps
//     the next system update upgrades, each "Updates with the system" (never one by one: no partial upgrade, S4, S12), the
//     other system packages; Update All… opens Software Update, which updates the whole system with its password and its
//     progress (SD32); Software Update… when only it can act (updates blocked, not set up).
//   - Flatpak apps (Flathub on): their updates (flatpak remote-ls --updates, S31), each with Update, and Update All for the
//     group; the runtimes' updates counted.
ScrollPage {
    id: root

    // StoreBackend::updates.
    property var updates: ({state: "unknown"})

    signal opened(string id)
    signal checkRequested
    signal softwareUpdateRequested
    signal flatpakUpdateAllRequested

    readonly property var apps: root.updates.apps || []
    readonly property var flatpak: root.updates.flatpak || ({on: false})
    readonly property var flatpakApps: root.flatpak.apps || []
    readonly property string systemAction: Store.systemAction(root.updates)

    title: qsTr("Updates")
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    // The state line and Check Now.
    Item {
        width: root.contentWidth
        implicitHeight: Math.max(status.implicitHeight, check.implicitHeight)

        Text {
            id: status
            anchors.left: parent.left
            anchors.right: check.left
            anchors.rightMargin: Tokens.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: Store.updatesStatus(root.updates)
            wrapMode: Text.Wrap
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBodySize
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Button {
            id: check
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            push: true
            text: qsTr("Check Now")
            enabled: !root.updates.checking && root.flatpak.state !== "checking"
            onClicked: root.checkRequested()
        }
    }

    // ---- The system (Software Update's).
    SectionHeading {
        width: root.contentWidth
        visible: root.flatpak.on
        text: qsTr("System")
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

    // The last system update did not finish (S12): Software Update finishes it.
    Text {
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        visible: (root.updates.unfinished || 0) > 0 && !root.updates.running
        textFormat: Text.PlainText
        text: qsTr("Some packages are newer in the repositories than on this computer. Nothing installs from the repositories until the system update is finished.")
        wrapMode: Text.Wrap
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBodySize
    }

    Row {
        spacing: Tokens.spacingMd
        visible: root.systemAction !== ""

        Button {
            push: true
            text: root.systemAction === "update" ? qsTr("Update All…") : qsTr("Software Update…")
            Accessible.description: qsTr("Opens Software Update in Settings, which updates the whole system.")
            onClicked: root.softwareUpdateRequested()
        }
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

    // ---- Flatpak apps (Flathub on): each one updates on its own, in the user's own folder (ADR-0037 d).
    Item {
        width: root.contentWidth
        visible: root.flatpak.on
        implicitHeight: Math.max(flatpakHeading.implicitHeight, updateAll.implicitHeight)

        SectionHeading {
            id: flatpakHeading
            anchors.left: parent.left
            anchors.right: updateAll.left
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Flatpak Apps")
        }

        Button {
            id: updateAll
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.flatpakApps.length > 0 || (root.flatpak.runtimes || 0) > 0
            push: true
            text: qsTr("Update All")
            enabled: (root.flatpak.block || "") === "" && root.flatpak.state !== "checking"
            Accessible.description: Store.getBlockText(root.flatpak.block || "", "flatpak")
            onClicked: root.flatpakUpdateAllRequested()
        }
    }

    Text {
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        visible: root.flatpak.on && text !== ""
        textFormat: Text.PlainText
        text: Store.flatpakUpdatesLine(root.flatpak)
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBodySize
    }

    Column {
        width: root.contentWidth
        visible: root.flatpak.on && root.flatpakApps.length > 0
        spacing: 0

        Repeater {
            model: root.flatpakApps

            delegate: AppLockup {
                required property var modelData
                required property int index
                width: root.contentWidth
                app: modelData
                separator: index < root.flatpakApps.length - 1
                onOpened: id => root.opened(id)
            }
        }
    }
}
