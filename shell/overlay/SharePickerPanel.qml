pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "../services/SharePicker.js" as Logic

// The screen-sharing picker (ADR-0035 D-6, step 7a; spec system-dialogs.md SP6, SP7): an app asked to share the screen
// through the portal and the stand-in of xdph's picker asked the shell (SharePicker). Entire Screen shows each display, Window
// each window xdph listed, grouped by app; both as live thumbnails. Nothing is selected at first: Share waits for a choice.
// Remember this choice (the portal's restore token) is unticked at every opening, whatever the app or xdph.conf ask (owner
// decision Q14). Nothing answers keys or clicks until the panel is armed (7-8). The picker cannot name the app (xdph does not
// pass it). Keys: arrows move in the grid, Return shares,
// Esc cancels, Cmd-1 and Cmd-2 (Super, forwarded as Ctrl) switch the tabs. Captures stop when the panel goes (the Overlay's
// Loader unloads it).
Dialog {
    id: root

    property string tab: "screen"
    // The chosen tile by what it stands for (SharePicker.js keyOf), never by its place: "" for none.
    property string chosen: ""
    property bool remember: false
    // False until Tokens.panelAlertArmMs after the panel showed, or after the last key pressed meanwhile (the access alert's
    // rule, AccessAlert.qml): keys typed for another window when it appears (Up then Return in a terminal) and clicks choose
    // and share nothing. Esc and Cancel always cancel.
    property bool armed: false
    readonly property var screens: Quickshell.screens
    readonly property var windows: Logic.ordered(SharePicker.windows, appId => Apps.nameFor(appId))
    readonly property var tiles: root.tab === "screen" ? root.screens : root.windows
    readonly property int current: Logic.indexOfKey(root.tab, root.tiles, root.chosen)
    readonly property int columns: Logic.columnsFor(grid.width, Tokens.panelSharePickerTileWidth, Tokens.spacingMd)

    function unarmed(): bool {
        if (root.armed)
            return false;
        arm.restart();
        return true;
    }

    function choose(index: int): void {
        root.chosen = index >= 0 && index < root.tiles.length ? Logic.keyOf(root.tab, root.tiles[index]) : "";
    }

    function shareCurrent(): void {
        if (root.current < 0 || !root.armed)
            return;
        SharePicker.share(root.tab, root.chosen, root.remember);
    }

    function show(tab: string): void {
        root.tab = tab;
        root.chosen = "";
        grid.forceActiveFocus();
    }

    title: qsTr("Share Your Screen")
    message: qsTr("An app wants to share your screen. Choose what it can see.")
    sheet: true
    panelWidth: Tokens.panelSharePickerWidth

    onRejected: SharePicker.cancel()

    Timer {
        id: arm
        interval: Tokens.panelAlertArmMs
        running: true
        onTriggered: root.armed = true
    }

    content: [
        SegmentedControl {
            width: parent.width
            fill: true
            accessibleName: qsTr("What to share")
            model: [
                {
                    id: "screen",
                    text: qsTr("Entire Screen")
                },
                {
                    id: "window",
                    text: qsTr("Window")
                }
            ]
            value: root.tab
            onPicked: id => root.show(id)
        },
        Rectangle {
            width: parent.width
            height: Tokens.panelSharePickerRows * grid.cellHeight + 2 * Tokens.spacingSm
            radius: Tokens.radiusControl
            color: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2) : Appearance.lightWellFill
            border.width: grid.activeFocus ? Tokens.controlFocusOutline : 1
            border.color: grid.activeFocus ? Appearance.focusRingColor : Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

            GridView {
                id: grid

                anchors.fill: parent
                anchors.margins: Tokens.spacingSm
                clip: true
                focus: true
                activeFocusOnTab: true
                cellWidth: width / root.columns
                cellHeight: Tokens.panelSharePickerThumbHeight + Tokens.menuItemHeight + Tokens.spacingSm
                model: root.tiles
                currentIndex: root.current
                Accessible.role: Accessible.List
                Accessible.name: root.tab === "screen" ? qsTr("Displays") : qsTr("Windows")

                Keys.onPressed: event => {
                    if (event.key !== Qt.Key_Escape && root.unarmed()) {
                        event.accepted = true;
                        return;
                    }
                    const cmd = (event.modifiers & Qt.ControlModifier) !== 0;
                    const keys = {
                        [Qt.Key_Left]: "left",
                        [Qt.Key_Right]: "right",
                        [Qt.Key_Up]: "up",
                        [Qt.Key_Down]: "down"
                    };
                    if (cmd && event.key === Qt.Key_1)
                        root.show("screen");
                    else if (cmd && event.key === Qt.Key_2)
                        root.show("window");
                    else if (!cmd && keys[event.key] !== undefined)
                        root.choose(Logic.moved(root.current, keys[event.key], root.tiles.length, root.columns));
                    else if (!cmd && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter))
                        root.shareCurrent();
                    else
                        return;
                    event.accepted = true;
                }

                delegate: Item {
                    id: tile

                    required property var modelData
                    required property int index
                    readonly property bool selected: root.current === tile.index
                    readonly property bool isScreen: root.tab === "screen"
                    readonly property var entry: tile.isScreen ? null : Apps.lookup(tile.modelData.appId)
                    readonly property var source: tile.isScreen ? tile.modelData : (tile.modelData.address !== "" ? Compositor.toplevelByAddress(tile.modelData.address) : null)
                    readonly property string label: tile.isScreen ? tile.modelData.name : (tile.modelData.title !== "" ? tile.modelData.title : Apps.nameFor(tile.modelData.appId))

                    width: grid.cellWidth
                    height: grid.cellHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: tile.isScreen ? tile.label : qsTr("%1, %2").arg(Apps.nameFor(tile.modelData.appId)).arg(tile.label)
                    Accessible.selected: tile.selected
                    Accessible.onPressAction: root.choose(tile.index)

                    Item {
                        id: thumb

                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Tokens.panelSharePickerTileWidth
                        height: Tokens.panelSharePickerThumbHeight

                        // The selected tile: the selection colour around it, as a list's selected row.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -Tokens.controlFocusOutline
                            radius: Tokens.radiusControl + Tokens.controlFocusOutline
                            color: "transparent"
                            border.width: Tokens.controlFocusOutline
                            border.color: Appearance.colors.selection
                            visible: tile.selected
                        }

                        // The display or the window fitted in its box with its own aspect, live. No source (xdph had no
                        // address for the window, or the shell does not know it): the app's icon instead.
                        ScreencopyView {
                            id: view

                            readonly property real ratio: implicitWidth > 0 && implicitHeight > 0 ? implicitWidth / implicitHeight : Tokens.panelSharePickerThumbAspect

                            anchors.centerIn: parent
                            width: ratio >= thumb.width / thumb.height ? thumb.width : thumb.height * ratio
                            height: ratio >= thumb.width / thumb.height ? thumb.width / ratio : thumb.height
                            captureSource: SharePicker.shown ? tile.source : null
                            live: true
                            paintCursor: false
                            visible: tile.source !== null
                        }

                        TintedIcon {
                            anchors.centerIn: parent
                            size: Tokens.panelSharePickerIconSize
                            visible: tile.source === null
                            source: ThemeIcons.appIcon(tile.entry ? tile.entry.icon : (tile.isScreen ? "" : tile.modelData.appId), "application-x-executable")
                            asynchronous: true
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: thumb.height + Tokens.spacingXs
                        height: Tokens.menuItemHeight
                        spacing: Tokens.spacingXs

                        TintedIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            size: Tokens.menuIconSize
                            visible: !tile.isScreen
                            source: ThemeIcons.appIcon(tile.entry ? tile.entry.icon : (tile.isScreen ? "" : tile.modelData.appId), "application-x-executable")
                            asynchronous: true
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, tile.width - Tokens.menuIconSize - Tokens.spacingXs)
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            text: tile.label
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyMenuSize
                            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            if (!root.armed)
                                return;
                            root.choose(tile.index);
                            grid.forceActiveFocus();
                        }
                        onDoubleClicked: {
                            if (!root.armed)
                                return;
                            root.choose(tile.index);
                            root.shareCurrent();
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: root.tiles.length === 0
                textFormat: Text.PlainText
                text: root.tab === "screen" ? qsTr("No display can be shared.") : qsTr("No window can be shared.")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        },
        CheckBox {
            text: qsTr("Remember this choice")
            checked: root.remember
            onToggled: root.remember = checked
        }
    ]

    buttons: [
        Button {
            text: qsTr("Cancel")
            onClicked: SharePicker.cancel()
        },
        Button {
            text: qsTr("Share")
            primary: true
            enabled: root.armed && root.current >= 0 && root.current < root.tiles.length
            onClicked: root.shareCurrent()
        }
    ]
}
