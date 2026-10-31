pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The device table of Sound > Output & Input (macOS 27): a column header (Name, Type) between two lines, then one row per
// device, every second one striped. The current device is selected: grey while the table does not have the focus, the accent
// with white text while it has it (a focused macOS table). A click on a row, or Up, Down, Home and End while the table has the
// focus, chooses a device. Placed as measured (docs/audits/settings-parity-2026-10-26.md § Sound).
Item {
    id: root

    // Rows: nodeId, name, kind, isDefault (System.syncModel keeps them in place across a refresh).
    property var model: null
    // The device being chosen, selected until the next reading says which one is the default (-1: none).
    property int pending: -1
    property string accessibleName: ""
    property string emptyText: ""
    // The Type column's text for a kind of System.audioKind.
    property var kindLabel: kind => kind
    // The table ends its group: the last row's fill follows the group's rounded corners.
    property bool roundBottom: false

    signal chosen(int nodeId)

    readonly property int count: root.model ? root.model.count : 0
    readonly property color lineColor: Appearance.colors.separator

    width: parent ? parent.width : implicitWidth
    implicitHeight: rows.y + (root.count > 0 ? rows.height : Tokens.settingsSoundTableRowHeight)
    activeFocusOnTab: root.count > 0
    Accessible.role: Accessible.List
    Accessible.name: root.accessibleName
    Accessible.focusable: true

    function isSelected(nodeId: int, isDefault: bool): bool {
        return root.pending >= 0 ? nodeId === root.pending : isDefault;
    }

    function selectedIndex(): int {
        for (let i = 0; i < root.count; i++) {
            const r = root.model.get(i);
            if (root.isSelected(r.nodeId, r.isDefault))
                return i;
        }
        return -1;
    }

    function chooseAt(i: int): void {
        if (i < 0 || i >= root.count)
            return;
        const r = root.model.get(i);
        if (!root.isSelected(r.nodeId, r.isDefault))
            root.chosen(r.nodeId);
    }

    Keys.onPressed: event => {
        const at = root.selectedIndex();
        if (event.key === Qt.Key_Down)
            root.chooseAt(at < 0 ? 0 : at + 1);
        else if (event.key === Qt.Key_Up)
            root.chooseAt(at < 0 ? root.count - 1 : at - 1);
        else if (event.key === Qt.Key_Home)
            root.chooseAt(0);
        else if (event.key === Qt.Key_End)
            root.chooseAt(root.count - 1);
        else
            return;
        event.accepted = true;
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Appearance.withAlpha(root.lineColor, Tokens.settingsSoundTableTopLineOpacity)
    }

    Rectangle {
        y: 1
        width: parent.width
        height: Tokens.settingsSoundTableHeaderHeight
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.settingsSoundTableStripeOpacity)
    }

    Text {
        textFormat: Text.PlainText
        x: Tokens.settingsSoundTableHeaderInset
        y: Tokens.settingsSoundTableHeaderBaseline - baselineOffset
        width: typeHeader.x - x - Tokens.spacingSm
        elide: Text.ElideRight
        text: qsTr("Name")
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        Accessible.ignored: true
    }

    Text {
        id: typeHeader
        textFormat: Text.PlainText
        x: Tokens.settingsSoundTableTypeColumn - (Tokens.settingsRowInset - Tokens.settingsSoundTableHeaderInset)
        y: Tokens.settingsSoundTableHeaderBaseline - baselineOffset
        width: root.width - x - Tokens.settingsRowInset
        elide: Text.ElideRight
        text: qsTr("Type")
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        Accessible.ignored: true
    }

    Rectangle {
        id: headerLine
        y: 1 + Tokens.settingsSoundTableHeaderHeight
        width: parent.width
        height: 1
        color: Appearance.withAlpha(root.lineColor, Tokens.settingsSoundTableHeaderLineOpacity)
    }

    Text {
        textFormat: Text.PlainText
        visible: root.count === 0
        x: Tokens.settingsRowInset
        y: rows.y + Tokens.settingsSoundTableRowBaseline - baselineOffset
        width: root.width - 2 * Tokens.settingsRowInset
        elide: Text.ElideRight
        text: root.emptyText
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Column {
        id: rows
        y: headerLine.y + headerLine.height
        width: parent.width

        Repeater {
            model: root.model

            delegate: Item {
                id: row

                required property int index
                required property int nodeId
                required property string name
                required property string kind
                required property bool isDefault

                readonly property bool selected: root.isSelected(row.nodeId, row.isDefault)
                readonly property bool emphasized: row.selected && root.activeFocus
                readonly property bool last: row.index === root.count - 1
                readonly property real cornerRadius: root.roundBottom && row.last ? Tokens.radiusGroup : 0

                width: rows.width
                height: Tokens.settingsSoundTableRowHeight
                Accessible.role: Accessible.ListItem
                Accessible.name: row.kind !== "" ? row.name + ", " + root.kindLabel(row.kind) : row.name
                Accessible.selectable: true
                Accessible.selected: row.selected
                Accessible.onPressAction: root.chooseAt(row.index)

                Rectangle {
                    anchors.fill: parent
                    bottomLeftRadius: row.cornerRadius
                    bottomRightRadius: row.cornerRadius
                    color: row.emphasized ? Appearance.colors.selection
                        : row.selected ? Appearance.withAlpha(Appearance.colors.fill, Tokens.settingsSoundTableSelectionOpacity)
                        : row.index % 2 === 1 ? Appearance.withAlpha(Appearance.colors.fill, Tokens.settingsSoundTableStripeOpacity) : "transparent"
                }

                Text {
                    textFormat: Text.PlainText
                    x: Tokens.settingsRowInset
                    y: Tokens.settingsSoundTableRowBaseline - baselineOffset
                    width: kindText.x - x - Tokens.spacingSm
                    elide: Text.ElideRight
                    text: row.name
                    color: row.emphasized ? Appearance.colors.selectionText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                Text {
                    id: kindText
                    textFormat: Text.PlainText
                    x: Tokens.settingsSoundTableTypeColumn
                    y: Tokens.settingsSoundTableRowBaseline - baselineOffset
                    width: row.width - x - Tokens.settingsRowInset
                    elide: Text.ElideRight
                    text: root.kindLabel(row.kind)
                    color: row.emphasized ? Appearance.colors.selectionText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.forceActiveFocus(Qt.MouseFocusReason);
                        root.chooseAt(row.index);
                    }
                }
            }
        }
    }
}
