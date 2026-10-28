pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The Store's settings (Ctrl+,; spec SR27, SR28): the optional sources (both off until turned on, owner ST2) and the
// screenshots' switch (owner ST6, on), read only until step 3 writes them; the catalog in use and why one is not; Arch's
// app data; what the Store fetches and from where, in plain words; Refresh.
Window {
    id: root

    required property var backend
    property string gfChromeRole: "info"

    readonly property var catalog: root.backend.catalog
    readonly property var appData: root.backend.appData
    readonly property var sources: root.backend.sources

    title: qsTr("Grassfield Store Settings")
    width: Tokens.storeSettingsWidth
    height: Math.min(Tokens.storeSettingsMaxHeight, content.implicitHeight + toolbar.height + 2 * Tokens.storeSettingsMargin)
    minimumWidth: Tokens.storeSettingsWidth
    maximumWidth: Tokens.storeSettingsWidth
    color: Appearance.colors.windowBackground

    function catalogLine(): string {
        switch (root.catalog.problem) {
        case "unconfigured":
            return qsTr("No catalog yet: this version of Grassfield has no catalog host.");
        case "untrusted":
            return qsTr("The catalog could not be verified: no trusted Grassfield key is installed yet.");
        case "refused":
            return qsTr("The catalog could not be verified.");
        case "unavailable":
            return root.catalog.inUse ? qsTr("The catalog could not be fetched; the copy from %1 is in use.").arg(root.catalog.date)
                                      : qsTr("The catalog could not be fetched.");
        }
        return root.catalog.inUse ? qsTr("The catalog from %1, verified.").arg(root.catalog.date) : "";
    }

    function appDataLine(): string {
        if (root.appData.problem === "unverified")
            return qsTr("Arch's app data could not be verified.");
        switch (root.appData.origin) {
        case "installed":
            return qsTr("Arch's app data: installed on this computer.");
        case "fetched":
            return qsTr("Arch's app data: fetched from your package mirror and verified.");
        }
        return qsTr("Arch's app data is not available yet: apps show their package's description.");
    }

    // Only while this window is the key window: Qt also matches its Shortcuts while the Store's window has the keyboard.
    Shortcut {
        sequences: ["Ctrl+W", "Esc"]
        enabled: root.backend.focusWindow === root
        onActivated: root.close()
    }

    UnifiedToolbar {
        id: toolbar
        width: parent.width
        window: root
        style: "titlebar"
        title: root.title
        doubleClickAction: root.backend.titlebarDoubleClick
        canMinimize: root.backend.canMinimize
    }

    Flickable {
        anchors.top: toolbar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentHeight: content.implicitHeight + 2 * Tokens.storeSettingsMargin
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: content
            x: Tokens.storeSettingsMargin
            y: Tokens.storeSettingsMargin
            width: parent.width - 2 * Tokens.storeSettingsMargin
            spacing: Tokens.storeSettingsGroupGap

            SettingsGroup {
                title: qsTr("Sources")

                SettingsSwitch {
                    title: qsTr("AUR")
                    detail: qsTr("Packages made by users and reviewed by no one. Their build script runs on this computer.")
                    checked: root.sources.aur
                }

                SettingsSwitch {
                    visible: root.sources.flatpak
                    title: qsTr("Flathub")
                    detail: qsTr("Apps from Flathub, installed in your own folder, without administrator rights.")
                    checked: root.sources.flathub
                }

                SettingsLine {
                    visible: !root.sources.flatpak
                    text: qsTr("Flathub needs the flatpak package.")
                }
            }

            SettingsGroup {
                title: qsTr("Screenshots")

                SettingsSwitch {
                    title: qsTr("Show screenshots")
                    detail: qsTr("Fetched when an app's page opens, from the addresses its description gives, often another site.")
                    checked: root.sources.screenshots
                }
            }

            SettingsGroup {
                title: qsTr("Catalog")

                SettingsLine {
                    text: qsTr("Channel: %1").arg(root.catalog.channel === "beta" ? qsTr("Beta") : qsTr("Stable"))
                }

                SettingsLine {
                    text: root.catalogLine()
                    visible: text !== ""
                }

                SettingsLine {
                    text: root.appDataLine()
                }

                Button {
                    push: true
                    text: root.backend.refreshing ? qsTr("Refreshing…") : qsTr("Refresh")
                    enabled: !root.backend.refreshing
                    onClicked: root.backend.refresh()
                }
            }

            SettingsGroup {
                title: qsTr("What the Store Fetches")

                SettingsLine {
                    text: qsTr("The Grassfield catalog, from Grassfield's package host: when the Store opens, at most every 6 hours, and on Refresh.")
                }

                SettingsLine {
                    text: qsTr("Arch's app data, from your package mirror, when it is not installed.")
                }

                SettingsLine {
                    text: qsTr("Screenshots, from the addresses in each app's description, when its page opens.")
                }

                SettingsLine {
                    text: qsTr("Nothing on a metered connection unless you choose Refresh. What you search for stays on this computer.")
                }
            }

            SettingsLine {
                text: qsTr("Turning the sources and the screenshots on and off comes in a later version.")
            }
        }
    }

    component SettingsGroup: Column {
        property string title: ""
        width: parent ? parent.width : 0
        spacing: Tokens.storeSettingsLineGap

        Text {
            textFormat: Text.PlainText
            text: parent.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuBoldWeight
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }
    }

    component SettingsLine: Text {
        width: parent ? parent.width : 0
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBadgeSize
    }

    component SettingsSwitch: Item {
        id: line
        property string title: ""
        property string detail: ""
        property bool checked: false
        width: parent ? parent.width : 0
        implicitHeight: Math.max(toggle.implicitHeight, texts.implicitHeight)

        Column {
            id: texts
            anchors.left: parent.left
            anchors.right: toggle.left
            anchors.rightMargin: Tokens.spacingMd
            spacing: Tokens.storeInfoLineGap

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: line.title
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: line.detail
                wrapMode: Text.Wrap
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
            }
        }

        Toggle {
            id: toggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: line.checked
            enabled: false
            accessibleName: line.title
        }
    }
}
