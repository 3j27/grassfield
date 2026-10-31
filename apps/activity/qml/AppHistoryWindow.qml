pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// App History (Windows 11's, spec AM67; ADR-0038 g, AD31): each app's use over a period, from systemd's records of the
// launches that ended and the live app units. A period pop-up (Last 12 Hours, Last 7 Days, Last 30 Days), a line "Resource
// use since <date> for <user>", and a sortable list: name and icon, CPU Time, Memory Peak, Launches, Last Used. Read when the
// window opens and when the period changes; nothing can be deleted. Without the journal: "Usage history isn't available."
// and nothing else. Opened by Main.qml as one of its own windows (View > App History, Ctrl+6).
Window {
    id: root

    required property var app
    // ADR-0015: the titlebar-only style, as Inspect and Files' Get Info.
    property string gfChromeRole: "info"
    readonly property var history: root.app.appHistory
    // The tests read them.
    readonly property alias periodPicker: periodPicker
    readonly property alias rows: rows
    readonly property alias unavailableText: unavailableText

    // The figures share the room after the name by weight: a date needs more than a count.
    readonly property var columns: [
        {key: "name", title: qsTr("Name"), numeric: false, weight: 0},
        {key: "cpu", title: qsTr("CPU Time"), numeric: true, weight: 1},
        {key: "memory", title: qsTr("Memory Peak"), numeric: true, weight: 1},
        {key: "launches", title: qsTr("Launches"), numeric: true, weight: 0.7},
        {key: "lastUsed", title: qsTr("Last Used"), numeric: true, weight: 1.3}
    ]
    readonly property real figureUnit: Math.max(0, (rows.width - Tokens.activityAppHistoryNameWidth) / 4)

    function widthOf(index: int): real {
        return index === 0 ? Tokens.activityAppHistoryNameWidth : root.figureUnit * root.columns[index].weight;
    }

    title: qsTr("App History")
    width: Tokens.activityAppHistoryWidth
    height: Tokens.activityAppHistoryHeight
    minimumWidth: Tokens.activityAppHistoryMinWidth
    minimumHeight: Tokens.activityAppHistoryMinHeight
    color: Appearance.colors.windowBackground
    visible: true

    Component.onCompleted: root.history.reload()

    Shortcut {
        sequences: [StandardKey.Close]
        enabled: root.app.focusWindow === root
        onActivated: root.close()
        onActivatedAmbiguously: root.close()
    }

    UnifiedToolbar {
        id: chrome
        width: parent.width
        window: root
        style: "titlebar"
        title: root.title
        doubleClickAction: root.app.titlebarDoubleClick
        canMinimize: root.app.canMinimize
    }

    Item {
        id: bar
        anchors.top: chrome.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Tokens.spacingMd
        height: periodPicker.implicitHeight

        ComboBox {
            id: periodPicker
            objectName: "periodPicker"
            accessibleName: qsTr("Period")
            visible: !root.history.unavailable
            model: root.history.periods.map(p => ({id: p.key, text: p.title}))
            value: root.history.period
            onPicked: id => root.history.period = id
        }

        Text {
            anchors.left: periodPicker.right
            anchors.leftMargin: Tokens.spacingMd
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.history.unavailable
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.history.caption
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }

    // AM67: no journal, the message alone.
    Text {
        id: unavailableText
        objectName: "unavailableText"
        anchors.centerIn: parent
        visible: root.history.unavailable
        textFormat: Text.PlainText
        text: qsTr("Usage history isn't available.")
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Row {
        id: headerRow
        objectName: "historyHeaders"
        visible: !root.history.unavailable
        anchors.top: bar.bottom
        anchors.topMargin: Tokens.spacingMd
        x: rows.x
        height: Tokens.activityHeaderHeight

        Repeater {
            model: root.columns

            delegate: Item {
                id: column
                required property var modelData
                required property int index
                readonly property bool active: root.history.sortKey === column.modelData.key
                width: root.widthOf(column.index)
                height: headerRow.height
                Accessible.role: Accessible.ColumnHeader
                Accessible.name: column.modelData.title
                Accessible.description: column.active ? (root.history.sortDescending ? qsTr("Sorted descending") : qsTr("Sorted ascending")) : ""
                Accessible.onPressAction: root.history.sortBy(column.modelData.key)

                Rectangle {
                    anchors.fill: parent
                    color: headerMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                }

                Rectangle {
                    visible: column.index > 0
                    width: Tokens.appsBorderWidth
                    height: parent.height - Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }

                Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Tokens.spacingSm
                    anchors.right: arrow.visible ? arrow.left : parent.right
                    anchors.rightMargin: arrow.visible ? 0 : Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: column.modelData.numeric ? Text.AlignRight : Text.AlignLeft
                    text: column.modelData.title
                    elide: Text.ElideRight
                    color: column.active ? Appearance.colors.text : Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.weight: column.active ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                }

                Icon {
                    id: arrow
                    visible: column.active
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    size: Tokens.activityChevronSize
                    color: Appearance.colors.textSecondary
                    rotation: root.history.sortDescending ? 0 : 180
                }

                MouseArea {
                    id: headerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.history.sortBy(column.modelData.key)
                }
            }
        }
    }

    Rectangle {
        visible: headerRow.visible
        anchors.top: headerRow.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    ListView {
        id: rows
        objectName: "historyRows"
        visible: !root.history.unavailable
        anchors.top: headerRow.bottom
        anchors.topMargin: Tokens.appsBorderWidth
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.history
        Accessible.role: Accessible.Table
        Accessible.name: root.title

        delegate: Item {
            id: row
            required property int index
            required property string name
            required property string icon
            required property string cpuTime
            required property string memoryPeak
            required property string launches
            required property string lastUsed
            required property string accessibleText
            readonly property var cells: [row.name, row.cpuTime, row.memoryPeak, row.launches, row.lastUsed]
            width: rows.width
            height: Tokens.activityRowHeight
            Accessible.role: Accessible.Row
            Accessible.name: row.accessibleText

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Tokens.spacingXs
                anchors.rightMargin: Tokens.spacingXs
                radius: Tokens.radiusControl
                color: row.index % 2 === 1 ? Appearance.withAlpha(Appearance.colors.fill, Tokens.activityRowAlternate) : "transparent"
            }

            Row {
                height: parent.height

                Repeater {
                    model: root.columns

                    delegate: Item {
                        id: cell
                        required property int index
                        readonly property bool isName: cell.index === 0
                        width: root.widthOf(cell.index)
                        height: row.height

                        Image {
                            id: glyph
                            visible: cell.isName
                            x: Tokens.spacingSm + Tokens.spacingXs
                            anchors.verticalCenter: parent.verticalCenter
                            width: Tokens.activityIconSize
                            height: Tokens.activityIconSize
                            sourceSize.width: Tokens.activityIconSize * 2
                            sourceSize.height: Tokens.activityIconSize * 2
                            source: cell.isName ? "image://icon/" + (row.icon !== "" ? row.icon : "application-x-executable") : ""
                            smooth: true
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.left: cell.isName ? glyph.right : parent.left
                            anchors.leftMargin: cell.isName ? Tokens.spacingXs : Tokens.spacingSm
                            anchors.right: parent.right
                            anchors.rightMargin: Tokens.spacingSm
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: cell.isName ? Text.AlignLeft : Text.AlignRight
                            elide: cell.isName ? Text.ElideMiddle : Text.ElideRight
                            text: row.cells[cell.index]
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.features: cell.isName ? {} : {"tnum": 1}
                        }
                    }
                }
            }
        }
    }

    ScrollBar {
        flickable: rows
        anchors.right: parent.right
        anchors.top: rows.top
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingXs
    }
}
