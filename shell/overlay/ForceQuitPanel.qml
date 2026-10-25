pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.platform
import qs.services

// Force Quit: lists open windows by app; choosing one asks for confirmation, then SIGKILLs the
// client PID reported by Hyprland. Nothing is killed without the second confirmation.
Dialog {
    id: root

    readonly property var windows: Compositor.toplevels ? Compositor.toplevels.values : []
    readonly property var selected: list.currentIndex >= 0 && list.currentIndex < windows.length ? windows[list.currentIndex] : null
    readonly property int selectedPid: selected ? Compositor.pidOf(selected) : 0

    title: qsTr("Force Quit Applications")
    message: qsTr("If an app is not responding, select it and choose Force Quit.")
    sheet: true
    panelWidth: Tokens.panelForceQuitWidth

    function ask(): void {
        if (!selected || selectedPid <= 1)
            return;
        Popups.confirm(qsTr("Force quit “%1”?").arg(Apps.nameFor(selected.appId)),
            qsTr("Unsaved changes in this application will be lost."), qsTr("Force Quit"), "forcequit", {pid: selectedPid}, true);
    }

    onRejected: Popups.close()

    // Windows opened after the shell started have no pid until Hyprland's list is refreshed.
    Component.onCompleted: Compositor.refreshToplevels()

    content: [
        Rectangle {
            width: parent.width
            height: 6 * Tokens.menuItemHeight + 2 * Tokens.spacingXs
            radius: Tokens.radiusControl
            color: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2) : Appearance.lightWellFill
            border.width: list.activeFocus ? Tokens.controlFocusOutline : 1
            border.color: list.activeFocus ? Appearance.focusRingColor : Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

            ListView {
                id: list
                anchors.fill: parent
                anchors.margins: Tokens.spacingXs
                clip: true
                focus: true
                activeFocusOnTab: true
                model: root.windows
                currentIndex: root.windows.length > 0 ? 0 : -1
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Open applications")
                Keys.onReturnPressed: root.ask()

                delegate: Item {
                    id: row

                    required property var modelData
                    required property int index
                    readonly property bool current: ListView.isCurrentItem

                    width: ListView.view.width
                    height: Tokens.menuItemHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: Apps.nameFor(row.modelData.appId)
                    Accessible.selected: row.current

                    Rectangle {
                        anchors.fill: parent
                        radius: Tokens.radiusControl
                        color: Appearance.colors.accent
                        visible: row.current
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Tokens.spacingSm
                        spacing: Tokens.spacingSm

                        TintedIcon {
                            size: Tokens.menuItemHeight - 6
                            overAccent: row.current
                            anchors.verticalCenter: parent.verticalCenter
                            source: {
                                const e = Apps.lookup(row.modelData.appId);
                                return ThemeIcons.appIcon(e ? e.icon : row.modelData.appId, "application-x-executable");
                            }
                            asynchronous: true
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: list.width - 3 * Tokens.spacingLg
                            elide: Text.ElideRight
                            text: Apps.nameFor(row.modelData.appId)
                            textFormat: Text.PlainText
                            color: row.current ? Appearance.colors.accentText : Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyMenuSize
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            list.currentIndex = row.index;
                            list.forceActiveFocus();
                        }
                        onDoubleClicked: root.ask()
                    }
                }
            }
        }
    ]

    buttons: [
        Button {
            text: qsTr("Cancel")
            onClicked: Popups.close()
        },
        Button {
            text: qsTr("Force Quit")
            primary: true
            destructive: true
            enabled: root.selectedPid > 1
            onClicked: root.ask()
        }
    ]
}
