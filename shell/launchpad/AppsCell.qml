pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// One cell of the Apps grid or of an open folder: icon, name under it, keyboard focus ring, drop
// indicators and the pointer handling (click activates, a press moved past the drag threshold
// starts a drag owned by `host`).
Item {
    id: root

    required property var info
    // The AppsWindow root item: owns the drag state (see beginDrag / dragMove / endDrag).
    required property var host
    required property int itemIndex
    property real cellW: Tokens.appsIconSize * Tokens.appsCellWidthScale
    property real cellH: Tokens.appsIconSize * Tokens.appsCellHeightScale
    property real iconSize: Tokens.appsIconSize
    property bool inFolder: false
    property bool dragEnabled: true
    property bool selected: false
    // False when the item is not on a displayed page (the cell stays, hidden).
    property bool shown: true

    signal activated

    readonly property bool real: info.kind !== "none"
    readonly property real labelHeight: Tokens.appsLabelSize * Tokens.appsLabelLineHeight
    readonly property bool beingDragged: host.dragging && host.dragKey === info.key
    readonly property bool dropMerge: !inFolder && host.dragging && host.hoverIndex === itemIndex && host.hoverMerge
    readonly property bool dropBefore: !inFolder && host.dragging && host.hoverIndex === itemIndex && !host.hoverMerge

    width: cellW
    height: cellH
    visible: real && shown
    Accessible.role: Accessible.Button
    Accessible.name: info.kind === "folder" ? qsTr("%1, folder").arg(info.name) : info.name
    Accessible.focused: selected
    Accessible.onPressAction: root.activated()

    readonly property real iconTop: (cellH - iconSize - Tokens.appsLabelGap - labelHeight) / 2

    Rectangle {
        // Hover, merge target.
        x: (root.cellW - root.iconSize) / 2 - Tokens.spacingSm
        y: root.iconTop - Tokens.spacingSm
        width: root.iconSize + 2 * Tokens.spacingSm
        height: root.iconSize + 2 * Tokens.spacingSm
        radius: root.iconSize * Tokens.appsFolderRadiusScale
        visible: root.dropMerge || (area.containsMouse && !root.host.dragging)
        color: Appearance.withAlpha(Appearance.colors.hover, root.dropMerge ? Tokens.materialHoverOpacity * 2 : Tokens.materialHoverOpacity)
        border.width: root.dropMerge ? Tokens.appsSelectionWidth : 0
        border.color: Appearance.colors.accent
    }

    Rectangle {
        // Reorder indicator: insertion bar on the left edge of the target.
        visible: root.dropBefore
        x: Tokens.appsDropBarInset
        y: root.iconTop
        width: Tokens.appsSelectionWidth
        height: root.iconSize
        radius: width / 2
        color: Appearance.colors.accent
    }

    Rectangle {
        // Keyboard focus ring.
        visible: root.selected && root.host.controller.keyNav || (root.selected && root.host.controller.searching)
        x: (root.cellW - root.iconSize) / 2 - Tokens.spacingSm
        y: root.iconTop - Tokens.spacingSm
        width: root.iconSize + 2 * Tokens.spacingSm
        height: root.iconSize + 2 * Tokens.spacingSm
        radius: root.iconSize * Tokens.appsFolderRadiusScale
        color: "transparent"
        border.width: Tokens.appsSelectionWidth
        border.color: Appearance.colors.accent
    }

    AppsIcon {
        x: (root.cellW - root.iconSize) / 2
        y: root.iconTop
        size: root.iconSize
        info: root.info
        opacity: root.beingDragged ? Tokens.appsDragSourceOpacity : 1
    }

    Text {
        x: Tokens.spacingXs
        y: root.iconTop + root.iconSize + Tokens.appsLabelGap
        width: root.cellW - 2 * Tokens.spacingXs
        height: root.labelHeight
        text: root.info.name ?? ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        color: Tokens.colorDark.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.appsLabelSize
        font.weight: Tokens.typographyMenuWeight
        opacity: root.beingDragged ? Tokens.appsDragSourceOpacity : 1
    }

    MouseArea {
        id: area

        property point pressPoint
        property bool moved: false

        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton

        onPressed: mouse => {
            pressPoint = mapToItem(root.host, mouse.x, mouse.y);
            moved = false;
        }

        onPositionChanged: mouse => {
            if (!pressed)
                return;
            const p = mapToItem(root.host, mouse.x, mouse.y);
            if (!moved && root.dragEnabled && Math.hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= Tokens.appsDragThreshold) {
                moved = true;
                root.host.beginDrag(root.info, p.x, p.y, root.inFolder);
            }
            if (moved)
                root.host.dragMove(p.x, p.y);
        }

        onReleased: mouse => {
            if (moved) {
                moved = false;
                root.host.endDrag();
            } else if (containsMouse) {
                root.activated();
            }
        }

        onCanceled: {
            if (moved) {
                moved = false;
                root.host.cancelDrag();
            }
        }
    }
}
