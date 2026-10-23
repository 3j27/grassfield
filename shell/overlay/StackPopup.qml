pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.dock
import qs.services
import "../dock/Stacks.js" as Stacks

// A folder stack of the Dock opened (macOS: click on Downloads): the folder's items as a Fan, a Grid or a List, sorted as the
// stack's options say, and "Open in Files". Payload (Popups.data): path, name, sort, view. Spec: docs/specs/dock.md requirement 25.
//
// Fan: the items rise from the tile along a curve, each with its name beside it, no panel (and no blur region: nothing is
// behind it but the icons). Grid and List: a rounded panel on the frosted material with a tail pointing at the tile (the host
// supplies the blur region). Keyboard: arrows move, Return opens, Esc closes. Items open through the open policy (gio open).
FocusScope {
    id: root

    readonly property var info: Popups.data
    readonly property string folderPath: info.path ? info.path : ""
    property var entries: []
    property bool loaded: false
    // Index of the item under the keyboard or pointer; entries.length is the "Open in Files" row. -1: none.
    property int currentIndex: -1

    readonly property string view: Stacks.resolveView(info.view, entries.length, Tokens.dockStackFanMax)
    readonly property bool fan: view === "fan"
    readonly property string align: Popups.align
    readonly property bool vertical: align === "rightOf" || align === "leftOf"

    // Fan: the number of items drawn and the "Open in Files" icon after them.
    readonly property int fanCount: Stacks.fanItems(entries.length, Tokens.dockStackFanMax)
    readonly property int rowCount: view === "list" ? Math.min(entries.length, Tokens.dockStackListMaxRows) : 0
    readonly property int columns: Stacks.gridColumns(entries.length, Tokens.dockStackGridMaxColumns)
    readonly property int gridRows: Math.max(1, Math.min(Tokens.dockStackGridMaxRows, Math.ceil(entries.length / columns)))
    readonly property real iconSize: Tokens.dockStackIconSize
    readonly property string openText: entries.length > fanCount && fan ? qsTr("%1 more in Files").arg(entries.length - fanCount) : qsTr("Open in Files")
    readonly property real labelMax: Tokens.dockStackListWidth
    readonly property var fanSlots: Stacks.fanLayout(fanCount + 1, Tokens.dockStackFanStep, Tokens.dockStackFanBend)

    // Panel (grid, list) size.
    readonly property real panelPad: Tokens.menuPadding + Tokens.spacingXs
    readonly property real footerHeight: Tokens.menuItemHeight + Tokens.spacingXs

    activeFocusOnTab: true
    focus: true
    Accessible.role: Accessible.PopupMenu
    Accessible.name: qsTr("%1 stack").arg(info.name ? info.name : Stacks.baseName(folderPath))

    width: {
        if (fan) {
            const side = Math.max(labelMax + Tokens.spacingSm + iconSize / 2, Tokens.dockStackFanBend + iconSize / 2);
            return vertical ? Tokens.dockStackFanStep * fanCount + iconSize + Tokens.spacingSm + labelMax : 2 * side;
        }
        return view === "list" ? Tokens.dockStackListWidth : columns * Tokens.dockStackCellWidth + 2 * panelPad;
    }
    height: {
        if (fan)
            return vertical ? 2 * (Tokens.dockStackFanBend + iconSize / 2) : Tokens.dockStackFanStep * fanCount + iconSize + Tokens.dockMenuTailGap;
        if (view === "list")
            return rowCount * Tokens.menuItemHeight + footerHeight + 2 * Tokens.menuPadding + Tokens.menuItemHeight / 2;
        return gridRows * Tokens.dockStackCellHeight + footerHeight + 2 * panelPad;
    }

    function open(index: int): void {
        const e = index >= 0 && index < entries.length ? entries[index] : null;
        const target = e ? e.path : folderPath;
        Popups.close();
        if (target !== "")
            Apps.openDetached(["gio", "open", target]);
    }

    function move(key: string): void {
        // The "Open in Files" row counts as one more item at the end.
        const count = entries.length + 1;
        const cols = view === "grid" ? columns : 1;
        currentIndex = Stacks.step(currentIndex, count, fan ? 1 : cols, key);
    }

    Keys.onEscapePressed: Popups.close()
    Keys.onUpPressed: move(fan ? "down" : "up")
    Keys.onDownPressed: move(fan ? "up" : "down")
    Keys.onLeftPressed: move("left")
    Keys.onRightPressed: move("right")
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Home) {
            move("home");
            event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            move("end");
            event.accepted = true;
        }
    }
    Keys.onReturnPressed: open(currentIndex)
    Keys.onEnterPressed: open(currentIndex)
    Keys.onSpacePressed: open(currentIndex)

    // The listing: one read-only `find` of the folder (shell/dock/list-folder.sh), sorted here.
    Process {
        id: lister
        command: ["sh", Quickshell.shellPath("dock/list-folder.sh"), root.folderPath]
        running: root.folderPath !== ""
        stdout: StdioCollector {
            onStreamFinished: {
                const all = Stacks.sortEntries(Stacks.parseListing(text, root.folderPath), root.info.sort);
                root.entries = all.slice(0, Tokens.dockStackItemMax);
                root.loaded = true;
                reveal.restart();
            }
        }
    }

    // The fan springs out of the tile; the other views fade in with the host.
    property real progress: 0

    NumberAnimation {
        id: reveal
        target: root
        property: "progress"
        from: 0
        to: 1
        duration: Appearance.duration(Tokens.motionNormal)
        easing.type: Easing.OutQuad
    }

    // ---- Fan ----

    Item {
        id: fanItem
        anchors.fill: parent
        visible: root.fan

        Repeater {
            model: root.fan ? root.fanCount + 1 : 0

            delegate: Item {
                id: slot

                required property int index
                readonly property bool isOpen: index === root.fanCount
                readonly property var entry: isOpen ? null : root.entries[index]
                readonly property var at: root.fanSlots[index] ? root.fanSlots[index] : ({out: 0, side: 0})
                readonly property real out: at.out * root.progress
                readonly property real side: at.side * root.progress
                readonly property bool current: root.currentIndex === (isOpen ? root.entries.length : index)
                // Centre of the icon in the fan's box.
                readonly property real cx: root.align === "above" ? root.width / 2 + side : (root.align === "rightOf" ? root.iconSize / 2 + out : root.width - root.iconSize / 2 - out)
                readonly property real cy: root.align === "above" ? root.height - root.iconSize / 2 - out : root.height / 2 - side
                // Names go on the side away from the bend: left of the icons of a bottom or right Dock, right of those of a left one.
                readonly property bool labelRight: root.align === "rightOf"

                x: cx - root.iconSize / 2
                y: cy - root.iconSize / 2
                width: root.iconSize
                height: root.iconSize
                opacity: root.progress
                Accessible.role: Accessible.Button
                Accessible.name: isOpen ? root.openText : entry ? entry.name : ""
                Accessible.onPressAction: root.open(isOpen ? -1 : index)

                StackIcon {
                    visible: !slot.isOpen
                    anchors.fill: parent
                    path: slot.entry ? slot.entry.path : ""
                    isDir: slot.entry ? slot.entry.isDir : false
                    size: root.iconSize
                }

                TintedIcon {
                    visible: slot.isOpen
                    anchors.fill: parent
                    size: root.iconSize
                    source: slot.isOpen ? Quickshell.iconPath("folder", "") : ""
                }

                Rectangle {
                    visible: slot.current
                    anchors.fill: parent
                    anchors.margins: -Tokens.spacingXs
                    radius: Tokens.radiusControl
                    color: "transparent"
                    border.width: Tokens.controlFocusOutline
                    border.color: Appearance.focusRingColor
                }

                Tooltip {
                    shown: root.fan && root.progress > 0
                    delay: 0
                    text: slot.isOpen ? root.openText : (slot.entry ? slot.entry.name : "")
                    x: slot.labelRight ? slot.width + Tokens.spacingSm : -width - Tokens.spacingSm
                    y: (slot.height - height) / 2
                    width: Math.min(implicitWidth, root.labelMax)
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Tokens.spacingXs
                    hoverEnabled: true
                    onEntered: root.currentIndex = slot.isOpen ? root.entries.length : slot.index
                    onClicked: root.open(slot.isOpen ? -1 : slot.index)
                }
            }
        }
    }

    // ---- Panel (Grid and List) ----

    Item {
        id: panelHost
        anchors.fill: parent
        visible: !root.fan
        opacity: root.loaded ? 1 : 0

        Material {
            id: panel
            anchors.fill: parent
            radius: Tokens.radiusMenu
        }

        // Grid
        Flickable {
            id: gridView
            visible: root.view === "grid"
            x: root.panelPad
            y: root.panelPad
            width: root.columns * Tokens.dockStackCellWidth
            height: root.gridRows * Tokens.dockStackCellHeight
            contentWidth: gridContent.width
            contentHeight: gridContent.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Grid {
                id: gridContent
                columns: root.columns

                Repeater {
                    model: root.view === "grid" ? root.entries : []

                    delegate: Item {
                        id: cell

                        required property var modelData
                        required property int index
                        readonly property bool current: root.currentIndex === index

                        width: Tokens.dockStackCellWidth
                        height: Tokens.dockStackCellHeight
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.name
                        Accessible.onPressAction: root.open(index)

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Tokens.spacingXs / 2
                            radius: Tokens.radiusControl
                            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2)
                            visible: cell.current
                            border.width: Tokens.controlFocusOutline
                            border.color: root.activeFocus ? Appearance.focusRingColor : "transparent"
                        }

                        StackIcon {
                            x: (parent.width - width) / 2
                            y: Tokens.spacingSm
                            path: cell.modelData.path
                            isDir: cell.modelData.isDir
                            size: root.iconSize
                        }

                        Text {
                            textFormat: Text.PlainText
                            x: Tokens.spacingXs
                            y: Tokens.spacingSm + root.iconSize + Tokens.spacingXs
                            width: parent.width - 2 * Tokens.spacingXs
                            text: cell.modelData.name
                            elide: Text.ElideMiddle
                            maximumLineCount: 2
                            wrapMode: Text.WrapAnywhere
                            horizontalAlignment: Text.AlignHCenter
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                            font.letterSpacing: Appearance.tracking(Tokens.typographyCaptionSize)
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: root.currentIndex = cell.index
                            onClicked: root.open(cell.index)
                        }
                    }
                }
            }
        }

        // List
        ListView {
            id: listView
            visible: root.view === "list"
            x: Tokens.menuPadding
            y: Tokens.menuPadding
            width: parent.width - 2 * Tokens.menuPadding
            height: root.rowCount * Tokens.menuItemHeight
            model: root.view === "list" ? root.entries : []
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.currentIndex < root.entries.length ? root.currentIndex : -1
            highlightFollowsCurrentItem: false
            onCurrentIndexChanged: if (currentIndex >= 0)
                positionViewAtIndex(currentIndex, ListView.Contain)

            delegate: Item {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: root.currentIndex === index

                width: ListView.view.width
                height: Tokens.menuItemHeight
                Accessible.role: Accessible.MenuItem
                Accessible.name: modelData.name
                Accessible.onPressAction: root.open(index)

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.radiusControl
                    color: Appearance.colors.accent
                    visible: row.current
                }

                StackIcon {
                    x: Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    path: row.modelData.path
                    isDir: row.modelData.isDir
                    size: Tokens.menuItemHeight - Tokens.spacingXs
                }

                Text {
                    textFormat: Text.PlainText
                    x: Tokens.menuItemPadding + Tokens.menuItemHeight
                    width: parent.width - x - Tokens.menuItemPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.name
                    elide: Text.ElideMiddle
                    color: row.current ? Appearance.colors.accentText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                    font.weight: Tokens.typographySmallWeight
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.currentIndex = row.index
                    onClicked: root.open(row.index)
                }
            }
        }

        // The footer: Open in Files (last row, after a separator).
        MenuSeparator {
            x: Tokens.menuPadding
            width: parent.width - 2 * Tokens.menuPadding
            y: parent.height - root.footerHeight - (root.view === "list" ? Tokens.menuPadding : root.panelPad) - height / 2
        }

        Item {
            id: openRow
            readonly property bool current: root.currentIndex === root.entries.length
            x: root.view === "list" ? Tokens.menuPadding : root.panelPad
            width: parent.width - 2 * x
            height: Tokens.menuItemHeight
            y: parent.height - height - (root.view === "list" ? Tokens.menuPadding : root.panelPad)
            Accessible.role: Accessible.MenuItem
            Accessible.name: root.openText
            Accessible.onPressAction: root.open(-1)

            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusControl
                color: Appearance.colors.accent
                visible: openRow.current
            }

            Text {
                textFormat: Text.PlainText
                x: Tokens.menuItemPadding
                anchors.verticalCenter: parent.verticalCenter
                text: root.openText
                color: openRow.current ? Appearance.colors.accentText : Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyMenuSize
                font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                font.weight: Tokens.typographySmallWeight
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.currentIndex = root.entries.length
                onClicked: root.open(-1)
            }
        }

        // Tail pointing at the tile (the same drawing as the Dock menu's).
        Shape {
            visible: root.align === "above"
            readonly property real hostX: Math.max(Tokens.panelPopupMargin, Math.min(root.Window.width - root.width - Tokens.panelPopupMargin, Popups.anchorX - root.width / 2))
            readonly property real tipX: Math.max(Tokens.radiusMenu + Tokens.dockMenuTailWidth / 2, Math.min(root.width - Tokens.radiusMenu - Tokens.dockMenuTailWidth / 2, Popups.anchorX - hostX))
            x: tipX - Tokens.dockMenuTailWidth / 2
            y: root.height - 1
            width: Tokens.dockMenuTailWidth
            height: Tokens.dockMenuTailHeight + 1
            preferredRendererType: Shape.CurveRenderer
            Accessible.ignored: true

            ShapePath {
                strokeWidth: 0
                fillColor: Appearance.withAlpha(Appearance.colors.materialTint, Appearance.tintAlpha(Appearance.effectiveTransparency))
                startX: 0
                startY: 0
                PathLine {
                    x: Tokens.dockMenuTailWidth
                    y: 0
                }
                PathLine {
                    x: Tokens.dockMenuTailWidth / 2
                    y: Tokens.dockMenuTailHeight + 1
                }
                PathLine {
                    x: 0
                    y: 0
                }
            }
        }
    }

    Behavior on opacity {
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionFast)
        }
    }
}
