pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Privacy.js" as Privacy

// One category of Privacy & Security (Main.qml opens it from PrivacyPage; ADR-0030): the applications the portal permission
// store holds for it, by name. Location, the background and the camera: each application with a switch (allowed or not; the
// store keeps what the portal reads, Privacy.allow). Remote desktop and screen sharing: the applications that may use a screen
// they were given before without asking; a click selects one, − (or Delete) forgets its saved selections (Privacy.forget), and
// the portal asks again next time. Every change goes through SystemService, so never in a dev session.
SettingsPage {
    id: root

    required property var backend
    required property var system
    // A key of Privacy.SWITCHES or Privacy.SAVED.
    property string key: "location"

    readonly property bool saved: Privacy.SAVED.indexOf(root.key) >= 0
    readonly property var apps: grants.list(root.key)
    property string selectedApp: ""
    readonly property var selected: root.apps.find(a => a.app === root.selectedApp) ?? null

    // What a category's switch or list means, under the list.
    readonly property string explanation: ({
            location: qsTr("Apps you allow can find out where this computer is. An app you do not allow is refused without being asked; an app not listed asks the first time."),
            background: qsTr("Apps you allow may run in the background when they ask. An app you do not allow is refused when it asks; an app not listed is allowed the first time it asks."),
            camera: qsTr("Apps you allow can use the camera. An app you do not allow is refused without being asked; an app not listed asks the first time."),
            remoteDesktop: qsTr("These apps can start a remote session again with the screens and devices you chose for them, without asking. Remove an app to be asked next time; if it is in a session now, end the session first."),
            screencast: qsTr("These apps can share the screen or window you chose for them again, without asking. Remove an app to be asked next time; if it is sharing now, stop sharing first.")
        })[root.key] ?? ""

    function forgetSelected(): void {
        if (root.selected !== null)
            grants.forget(root.key, root.selected);
    }

    PrivacyState {
        id: grants
        backend: root.backend
        system: root.system
    }

    SettingsGroup {
        visible: !root.saved
        footnote: grants.error !== "" ? qsTr("The permissions cannot be read: %1.").arg(grants.error)
            : root.system.errors["privacy.act"] !== undefined ? qsTr("The change could not be made: %1.").arg(root.system.errors["privacy.act"]) : root.explanation

        Repeater {
            model: root.saved ? [] : root.apps

            LoginItemRow {
                required property var modelData
                // An app of the host for a grant the portal does not read for it: no switch, it would change nothing.
                readonly property bool unlimited: modelData.host && Privacy.HOST_READ.indexOf(root.key) < 0
                readonly property string appId: modelData.name !== modelData.app ? modelData.app : ""
                icon: modelData.icon
                title: modelData.name
                // An id that differs from the name says which app it is (a Flatpak id).
                subtitle: !unlimited ? appId : appId !== "" ? appId + " · " + qsTr("Not sandboxed: not limited") : qsTr("Not sandboxed: not limited")
                showToggle: !unlimited
                checked: modelData.allowed
                toggleEnabled: !grants.busy
                onToggled: c => grants.setAllowed(root.key, modelData.app, c)
            }
        }

        SettingsRow {
            visible: grants.loaded && root.apps.length === 0
            title: qsTr("No apps have asked")
        }
    }

    SettingsGroup {
        visible: root.saved
        footnote: grants.error !== "" ? qsTr("The permissions cannot be read: %1.").arg(grants.error)
            : root.system.errors["privacy.act"] !== undefined ? qsTr("The change could not be made: %1.").arg(root.system.errors["privacy.act"]) : root.explanation

        // The list is one focus stop: Up and Down move the selection, Delete forgets it (macOS table).
        FocusScope {
            id: list
            width: parent.width
            height: rows.height
            activeFocusOnTab: true
            Accessible.role: Accessible.List
            Accessible.name: root.title

            Keys.onPressed: event => {
                const i = root.apps.findIndex(a => a.app === root.selectedApp);
                if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                    if (root.apps.length > 0)
                        root.selectedApp = root.apps[Math.max(0, Math.min(root.apps.length - 1, i < 0 ? 0 : i + (event.key === Qt.Key_Down ? 1 : -1)))].app;
                    event.accepted = true;
                } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                    root.forgetSelected();
                    event.accepted = true;
                }
            }

            Column {
                id: rows
                width: parent.width

                Repeater {
                    model: root.saved ? root.apps : []

                    LoginItemRow {
                        required property var modelData
                        icon: modelData.icon
                        title: modelData.name
                        readonly property string count: modelData.tokens.length === 1 ? qsTr("1 saved choice") : qsTr("%1 saved choices").arg(modelData.tokens.length)
                        // An id that differs from the name says which app it is (a desktop entry can borrow a name).
                        subtitle: modelData.name !== modelData.app ? modelData.app + " · " + count : count
                        showToggle: false
                        selected: modelData.app === root.selectedApp
                        onClicked: {
                            root.selectedApp = modelData.app;
                            list.forceActiveFocus();
                        }
                    }
                }

                SettingsRow {
                    visible: grants.loaded && root.apps.length === 0
                    title: qsTr("No saved choices")
                }
            }

            FocusRing {
                shapeRadius: Tokens.radiusMenu
                visible: list.activeFocus
            }
        }

        ListFooter {
            canAdd: false
            canRemove: root.selected !== null && !grants.busy
            addName: qsTr("Add an app")
            removeName: qsTr("Remove the selected app")
            onRemoveClicked: root.forgetSelected()
        }
    }

    DevNote {
        system: root.system
    }
}
