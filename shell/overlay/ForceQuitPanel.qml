pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.platform
import qs.services

// Force Quit: lists open windows by app; choosing one asks for confirmation, then SIGKILLs the
// client PID reported by Hyprland. Nothing is killed without the second confirmation. An app that does not respond
// (NotResponding, ADR-0035 D-3) shows "(Not Responding)" in the destructive colour and is selected when the panel opens.
Dialog {
    id: root

    readonly property var windows: Compositor.toplevels ? Compositor.toplevels.values : []
    readonly property var selected: list.currentIndex >= 0 && list.currentIndex < windows.length ? windows[list.currentIndex] : null
    readonly property int selectedPid: selected ? Compositor.pidOf(selected) : 0
    // The class Hyprland reports for the selected window: the confirmation checks that the pid still owns a window of it.
    readonly property string selectedClass: {
        const top = selected ? Compositor.hyprlandToplevel(selected) : null;
        return top && top.lastIpcObject && top.lastIpcObject.class ? top.lastIpcObject.class : "";
    }

    // The selection follows a window, not a row: the window list is a new array each time a window opens or closes, which
    // resets the view's row. Before the user moves it, it goes onto the first app that does not respond and never away from
    // the app shown when a mark clears (NotResponding.selectionAfterChange, ADR-0035 decision 3-13).
    readonly property int preferred: NotResponding.initialIndex(windows.map(t => Compositor.pidOf(t)))
    property var current: null
    property bool userMoved: false

    function select(index: int): void {
        list.currentIndex = index;
        current = index >= 0 && index < windows.length ? windows[index] : null;
        if (index >= 0)
            list.positionViewAtIndex(index, ListView.Contain);
    }

    function userSelect(index: int): void {
        userMoved = true;
        select(index);
    }

    function sync(): void {
        const kept = current ? windows.indexOf(current) : -1;
        const marked = preferred >= 0 && preferred < windows.length && NotResponding.isMarked(Compositor.pidOf(windows[preferred]));
        select(NotResponding.selectionAfterChange(userMoved, kept, preferred, marked));
    }

    onPreferredChanged: sync()
    // After the view took its new model (which resets its row).
    onWindowsChanged: Qt.callLater(sync)

    title: qsTr("Force Quit Applications")
    message: qsTr("If an app is not responding, select it and choose Force Quit.")
    sheet: true
    panelWidth: Tokens.panelForceQuitWidth

    function ask(): void {
        if (!selected || selectedPid <= 1)
            return;
        Popups.confirm(qsTr("Force quit “%1”?").arg(Apps.nameFor(selected.appId)),
            qsTr("Unsaved changes in this application will be lost."), qsTr("Force Quit"), "forcequit", {pid: selectedPid, cls: selectedClass}, true);
    }

    onRejected: Popups.close()

    // Windows opened after the shell started have no pid until Hyprland's list is refreshed.
    Component.onCompleted: {
        Compositor.refreshToplevels();
        sync();
    }

    content: [
        Rectangle {
            width: parent.width
            height: 6 * Tokens.menuItemHeight + 2 * Tokens.spacingXs
            radius: Tokens.radiusControl
            color: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2) : Appearance.lightWellFill
            border.width: 1
            border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

            // The well keeps its hairline; the shared ring goes round it while the list has the keyboard (ADR-0039 step 7).
            KeyFocus {
                id: listFocus
                target: list
                // The list has the focus on open: the pointer's when a click opened the panel (step 8).
                pointer: Popups.openedByPointer
            }

            FocusRing {
                visible: listFocus.active
            }

            ListView {
                id: list
                anchors.fill: parent
                anchors.margins: Tokens.spacingXs
                clip: true
                focus: true
                activeFocusOnTab: true
                model: root.windows
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Open applications")
                Keys.onReturnPressed: root.ask()
                Keys.onUpPressed: root.userSelect(Math.max(0, list.currentIndex - 1))
                Keys.onDownPressed: root.userSelect(Math.min(root.windows.length - 1, list.currentIndex + 1))

                delegate: Item {
                    id: row

                    required property var modelData
                    required property int index
                    readonly property bool current: ListView.isCurrentItem
                    readonly property bool notResponding: NotResponding.isMarked(Compositor.pidOf(row.modelData))

                    width: ListView.view.width
                    height: Tokens.menuItemHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: row.notResponding ? qsTr("%1 (Not Responding)").arg(Apps.nameFor(row.modelData.appId)) : Apps.nameFor(row.modelData.appId)
                    Accessible.selected: row.current

                    Rectangle {
                        anchors.fill: parent
                        radius: Tokens.radiusControl
                        color: Appearance.colors.selection
                        visible: row.current
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Tokens.spacingSm
                        spacing: Tokens.spacingSm

                        TintedIcon {
                            size: Tokens.panelForceQuitIconSize
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
                            text: row.notResponding ? qsTr("%1 (Not Responding)").arg(Apps.nameFor(row.modelData.appId)) : Apps.nameFor(row.modelData.appId)
                            textFormat: Text.PlainText
                            color: row.current ? Appearance.colors.selectionText : (row.notResponding ? Appearance.colors.danger : Appearance.colors.text)
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyMenuSize
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.userSelect(row.index);
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
