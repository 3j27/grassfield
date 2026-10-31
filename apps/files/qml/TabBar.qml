pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TabsLogic.js" as TabsLogic

// The tab bar of a browser window (docs/specs/files.md "Tabs and windows"; the macOS 26/27 AppKit tab bar the Finder
// uses): a capsule track with one equal-width tab per BrowserTab, the current tab a lighter pill, a close button on the
// hovered tab and a round + after the track. A tab drags to reorder, onto another window's tab bar to move there, and
// out of every Files window to become a window of its own (TabsLogic, Main.qml). Files dropped on a tab are copied or
// moved into its folder (FilesApp.drop), and a tab hovered during a file drag comes to the front after the
// spring-loading delay.
Item {
    id: root

    // BrowserWindow.qml.
    required property var win
    readonly property var app: root.win.app
    readonly property int count: root.win.tabs.length
    // The tab of this bar being dragged (its index), -1 otherwise.
    property int dragFrom: -1
    // The slot a dragged tab hovers in this bar, -1 while no tab is dragged over it.
    property int hoverSlot: -1
    // A tab of another window hovers this bar: a slot opens for it.
    readonly property bool incoming: root.hoverSlot >= 0 && root.dragFrom < 0
    // A tab of this bar was dragged out of it: the others close the gap.
    readonly property bool outgoing: root.dragFrom >= 0 && root.hoverSlot < 0
    readonly property int slots: root.count + (root.incoming ? 1 : 0) - (root.outgoing ? 1 : 0)
    readonly property real tabWidth: TabsLogic.tabWidth(track.width, root.slots)

    readonly property color trackColor: Appearance.withAlpha(Appearance.colors.fill, Appearance.dark ? Tokens.materialFillOpacity : Tokens.filesTabTrackOpacityLight)
    readonly property color pillColor: Appearance.withAlpha(Appearance.colors.chipFill, Appearance.dark ? Tokens.materialFillOpacity : Tokens.filesTabPillOpacityLight)

    implicitHeight: Tokens.filesTabBarHeight
    Accessible.role: Accessible.PageTabList
    Accessible.name: qsTr("Tabs")

    // The slot under `x` (bar coordinates) for a tab dragged over this bar.
    function updateHover(x: real): void {
        const s = root.count + (root.dragFrom < 0 ? 1 : 0);
        root.hoverSlot = TabsLogic.slotAt(x - track.x, TabsLogic.tabWidth(track.width, s), s);
    }

    // Files dropped on `tab`: copied or moved into its folder by Files itself (FilesApp.drop). The source is told "copy",
    // as at every other drop point of Files: a "move" answer would let it delete its files while a copy to another
    // volume still runs.
    function dropFiles(drop: var, tab: var): void {
        if (!drop.hasUrls)
            return;
        root.app.drop(drop.urls, tab.folder.url, tab.folder);
        drop.accept(Qt.CopyAction);
    }

    function tabMenu(index: int, x: real, y: real): void {
        const items = [
            {id: "close", text: qsTr("Close Tab")},
            {id: "closeOthers", text: qsTr("Close Other Tabs"), enabled: root.count > 1},
            {separator: true},
            {id: "moveToWindow", text: qsTr("Move Tab to New Window"), enabled: root.count > 1}
        ];
        const tab = root.win.tabs[index];
        root.win.menuLayer.open(items, x, y, id => {
            if (id === "close")
                root.win.closeTab(root.win.tabs.indexOf(tab));
            else if (id === "closeOthers")
                root.win.closeOtherTabs(tab);
            else if (id === "moveToWindow")
                root.win.manager.moveTabToNewWindow(tab);
        }, root.win.tab ? root.win.tab.view : null, false);
    }

    // The dragged tab: a platform drag (it can leave the window), carrying "<pid>:<tab id>".
    Item {
        id: dragProxy

        property var tab: null

        width: 1
        height: 1
        Drag.dragType: Drag.Automatic
        // The grab is made at the tab's size; a size request on a grabbed image is refused (with a warning).
        Drag.imageSourceSize: Qt.size(-1, -1)
        Drag.supportedActions: Qt.MoveAction
        Drag.proposedAction: Qt.MoveAction
        // A drop on a Files window was only recorded (Main.qml draggedTab): the manager moves the tab now that the
        // drag is over, from the event loop.
        Drag.onDragFinished: dropAction => {
            const tab = dragProxy.tab;
            const outside = root.win.manager.tabDragAreas <= 0;
            dragProxy.Drag.active = false;
            dragProxy.tab = null;
            root.dragFrom = -1;
            root.hoverSlot = -1;
            // Dropped outside every Files window (nothing took it): the tab becomes a window (Finder). A cancelled drag
            // that ended outside the windows does the same (the platform reports no difference).
            root.win.manager.tabDragFinished(dropAction === Qt.IgnoreAction && outside && tab !== null);
        }
    }

    Rectangle {
        id: track
        x: Tokens.filesTabBarInset
        width: Math.max(0, root.width - track.x - Tokens.filesTabPlusGap - plus.width - Tokens.filesTabBarInset)
        height: Tokens.filesTabHeight
        radius: height / 2
        color: root.trackColor

        Repeater {
            model: root.win.tabs

            delegate: Item {
                id: tabItem

                required property var modelData
                required property int index
                readonly property bool current: tabItem.index === root.win.currentIndex
                // A HoverHandler sees the pointer over the close button too (a MouseArea's containsMouse would not).
                readonly property bool hovered: tabHover.hovered || fileDrop.containsDrag
                // Files can be dropped into a writable folder (not a search, not this tab's own items).
                readonly property bool acceptsFiles: tabItem.modelData.folder !== null && tabItem.modelData.folder.writable === true
                                                     && tabItem.modelData.folder.isSearch !== true

                x: TabsLogic.visualSlot(tabItem.index, root.dragFrom, root.hoverSlot) * root.tabWidth
                width: root.tabWidth
                height: track.height
                // The dragged tab is the drag image while it moves.
                opacity: tabItem.index === root.dragFrom ? 0 : 1
                Accessible.role: Accessible.PageTab
                Accessible.name: tabItem.modelData.title
                Accessible.selected: tabItem.current
                Accessible.onPressAction: root.win.selectTab(tabItem.index)

                // Tabs make room for a dragged one on the move curve; under Reduce Motion they take their place without
                // sliding (ADR-0039 D2 and step 23; the dragged tab itself follows the pointer).
                Behavior on x {
                    enabled: (root.dragFrom >= 0 || root.hoverSlot >= 0) && !Appearance.reduceMotion
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionFast)
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.curve
                    }
                }

                // The current tab's pill; a hovered tab shows it faintly.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: Tokens.filesTabPillInset
                    radius: height / 2
                    visible: tabItem.current || tabItem.hovered
                    opacity: tabItem.current ? 1 : Tokens.materialHoverActiveFactor * Tokens.materialHoverOpacity
                    color: root.pillColor
                }

                Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    width: Math.max(0, parent.width - 2 * (Tokens.filesTabCloseSize + Tokens.spacingSm))
                    horizontalAlignment: Text.AlignHCenter
                    text: DisplayName.text(tabItem.modelData.title)
                    elide: Text.ElideMiddle
                    color: tabItem.current ? Appearance.colors.text : Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.weight: Tokens.typographyMenuWeight
                }

                HoverHandler {
                    id: tabHover
                }

                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    drag.target: root.count > 0 ? dragProxy : null
                    drag.threshold: Tokens.filesDragThreshold
                    // The drag image is grabbed at the press (asynchronous); a drag that starts before it is ready goes
                    // without one rather than with an older tab's.
                    onPressed: mouse => {
                        if (mouse.button !== Qt.LeftButton)
                            return;
                        tabItem.dragImage = "";
                        tabItem.grabToImage(result => tabItem.dragImage = result.url);
                    }
                    onClicked: mouse => {
                        if (mouse.button === Qt.MiddleButton) {
                            root.win.closeTab(tabItem.index);
                        } else if (mouse.button === Qt.RightButton) {
                            const p = tabMouse.mapToItem(null, mouse.x, mouse.y);
                            root.tabMenu(tabItem.index, p.x, p.y);
                        } else {
                            root.win.selectTab(tabItem.index);
                        }
                    }
                    drag.onActiveChanged: {
                        if (!drag.active)
                            return;
                        dragProxy.tab = tabItem.modelData;
                        dragProxy.Drag.mimeData = ({[TabsLogic.tabMimeType]: root.app.processId + ":" + tabItem.modelData.tabId});
                        dragProxy.Drag.imageSource = tabItem.dragImage;
                        root.dragFrom = tabItem.index;
                        root.hoverSlot = tabItem.index;
                        root.win.manager.tabDragStarted(tabItem.modelData);
                        // The platform drag runs a nested event loop until it ends: nothing may destroy this tab bar or
                        // its tabs meanwhile (Main.qml draggedTab).
                        dragProxy.Drag.active = true;
                    }
                }

                property url dragImage

                // A file drag over the tab: drop into its folder, or wait to bring it to the front.
                DropArea {
                    id: fileDrop
                    anchors.fill: parent
                    keys: ["text/uri-list"]
                    enabled: tabItem.acceptsFiles
                    onEntered: drag => {
                        if (!tabItem.current)
                            spring.restart();
                    }
                    onExited: spring.stop()
                    onDropped: drop => {
                        spring.stop();
                        root.dropFiles(drop, tabItem.modelData);
                    }
                }

                Timer {
                    id: spring
                    interval: Tokens.filesSpringDelay
                    onTriggered: root.win.selectTab(tabItem.index)
                }

                ToolButton {
                    visible: tabHover.hovered && root.dragFrom < 0
                    anchors.left: parent.left
                    anchors.leftMargin: Tokens.filesTabPillInset + Tokens.spacingXs
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: Tokens.filesTabCloseSize
                    glyphSize: Tokens.filesTabCloseSize - Tokens.spacingXs
                    capsule: true
                    iconName: "close-glyph"
                    tint: Appearance.windowSecondary
                    accessibleName: qsTr("Close Tab")
                    onClicked: root.win.closeTab(tabItem.index)
                }
            }
        }
    }

    // The round + after the track: a new tab at the new-window location (Finder).
    Rectangle {
        id: plus
        anchors.right: parent.right
        anchors.rightMargin: Tokens.filesTabBarInset
        y: track.y
        width: Tokens.filesTabHeight
        height: width
        radius: width / 2
        color: Appearance.dark ? root.pillColor : Appearance.colors.chipFill
        border.width: Tokens.appsBorderWidth
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

        ToolButton {
            anchors.centerIn: parent
            buttonSize: plus.width
            capsule: true
            accessibleName: qsTr("New Tab")
            onClicked: root.win.newTab(root.app.newWindowUrl, null)

            ViewGlyph {
                anchors.centerIn: parent
                kind: "plus"
                size: Tokens.filesTabPlusGlyph
            }
        }
    }

    // A dragged tab over this bar: the slot it would take opens; dropped, it moves here (Main.qml dropTab).
    DropArea {
        anchors.fill: parent
        keys: [TabsLogic.tabMimeType]
        onEntered: drag => {
            root.win.manager.tabDragAreas++;
            root.updateHover(drag.x);
        }
        onPositionChanged: drag => root.updateHover(drag.x)
        onExited: {
            root.win.manager.tabDragAreas = Math.max(0, root.win.manager.tabDragAreas - 1);
            root.hoverSlot = -1;
        }
        onDropped: drop => {
            const id = TabsLogic.tabIdFrom(drop.getDataAsString(TabsLogic.tabMimeType), root.app.processId);
            const slot = root.hoverSlot;
            root.hoverSlot = -1;
            if (id < 0)
                return;
            root.win.manager.dropTab(id, root.win, slot);
            drop.accept(Qt.MoveAction);
        }
    }
}
