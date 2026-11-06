pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Inspect (spec AM57 to AM59; ADR-0038 AD13, AD45): a window "<name> (<pid>)" per process. Its header (Parent Process,
// which a click inspects, Process Group, User, % CPU, Recent hangs), the tabs Memory, Statistics and Open Files and Ports,
// and Quit (AM50's sheets, this process alone). The backend reads at the update frequency while the window is on screen;
// the window closes when the process ends. Opened by Main.qml as one of its own windows.
Window {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    // The app's backend and this window's inspection (src/inspection.h).
    required property var app
    required property var inspection
    // The main window: its close quits the app (AD17), as the app's own row's Quit does (AM54).
    property var mainWindow: null
    // ADR-0015: the titlebar-only style, as Files' Get Info.
    property string gfChromeRole: "info"
    // The tests read them.
    readonly property alias tabs: tabs
    readonly property alias quitButton: quitButton
    readonly property alias parentLink: parentLink
    readonly property alias sheets: sheets
    readonly property alias rowList: rowList

    title: root.inspection.title
    width: Tokens.activityInspectWidth
    height: Tokens.activityInspectHeight
    minimumWidth: Tokens.activityInspectMinWidth
    minimumHeight: Tokens.activityInspectMinHeight
    color: Appearance.colors.windowBackground
    visible: true

    // The rows of the tab shown, a list that changes in place at each read (its scroll position stays): {label, value}, or
    // {fd, text} for Open Files and Ports.
    readonly property bool filesTab: root.inspection.tab === "files"
    readonly property var rows: root.inspection.tab === "statistics" ? root.inspection.statisticsModel
        : root.filesTab ? root.inspection.filesModel : root.inspection.memoryModel
    // The labels' columns, right-aligned: as wide as their longest label (French ones run longer), never narrower than the
    // token, always leaving the values their room.
    readonly property var headerLabels: [qsTr("Parent Process:"), qsTr("Process Group:"), qsTr("User:"), qsTr("% CPU:"), qsTr("Recent hangs:")]
    readonly property real headerLabelWidth: root.labelWidth(root.headerLabels, header.width)
    readonly property real rowLabelWidth: root.filesTab ? 0 : root.labelWidth(root.inspection.rowLabels, rowList.width)

    function labelWidth(labels: var, room: real): real {
        let widest = Tokens.activityInspectLabelWidth;
        for (const label of labels)
            widest = Math.max(widest, Math.ceil(labelMetrics.advanceWidth(label)));
        return Math.max(0, Math.min(widest, room - Tokens.spacingSm - Tokens.activityInspectValueMinWidth));
    }

    FontMetrics {
        id: labelMetrics
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Component.onCompleted: root.inspection.watch(root)
    // The inspection goes with its window (Main.qml destroys a closed one), after its bindings: none reads a deleted one.
    Component.onDestruction: root.app.closeInspection(root.inspection)

    // AD45: the process ended.
    Connections {
        target: root.inspection
        function onEnded(): void {
            root.close();
        }
    }

    // AM54: the app's own row was quit from here: the main window closes, which quits the app.
    Connections {
        target: root.inspection.actions
        function onCloseWindowRequested(): void {
            if (root.mainWindow)
                root.mainWindow.close();
        }
    }

    // A key belongs to the key window alone (as Files' Get Info): Qt also matches this window's Shortcuts while the main
    // window has the keyboard.
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

    component Pair: Item {
        id: pair
        property string label
        property string value
        property real labelWidth: root.headerLabelWidth
        width: parent ? parent.width : 0
        height: Math.max(labelText.implicitHeight, valueText.implicitHeight)
        Accessible.role: Accessible.StaticText
        Accessible.name: pair.label + " " + pair.value

        Text {
            id: labelText
            width: pair.labelWidth
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            wrapMode: Text.Wrap // a narrow window: the label on two lines rather than cut
            text: pair.label
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Text {
            id: valueText
            x: pair.labelWidth + Tokens.spacingSm
            width: pair.width - x
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            text: pair.value
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.features: {"tnum": 1}
        }
    }

    Column {
        id: header
        x: Tokens.spacingLg
        y: chrome.height + Tokens.spacingMd
        width: parent.width - 2 * Tokens.spacingLg
        spacing: Tokens.spacingXs

        // AM57: Parent Process, its name and pid; a click inspects it.
        Item {
            width: parent.width
            height: Math.max(parentLabel.implicitHeight, parentLink.implicitHeight)
            Accessible.role: Accessible.Grouping
            Accessible.name: parentLabel.text

            Text {
                id: parentLabel
                width: root.headerLabelWidth
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: root.headerLabels[0]
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            LinkText {
                id: parentLink
                objectName: "parentLink"
                x: root.headerLabelWidth + Tokens.spacingSm
                width: Math.min(implicitWidth, parent.width - x)
                maximumLineCount: 1
                text: root.inspection.parentText
                visible: root.inspection.canInspectParent
                onActivated: root.inspection.inspectParent()
            }

            Text {
                x: parentLink.x
                width: parent.width - x
                visible: !parentLink.visible
                textFormat: Text.PlainText
                text: root.inspection.parentText
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

        Pair {
            label: root.headerLabels[1]
            value: root.inspection.groupText
        }
        Pair {
            label: root.headerLabels[2]
            value: root.inspection.userText
        }
        Pair {
            label: root.headerLabels[3]
            value: root.inspection.cpuText
        }
        Pair {
            label: root.headerLabels[4]
            value: root.inspection.hangsText
        }
    }

    SegmentedControl {
        id: tabs
        objectName: "inspectTabs"
        anchors.horizontalCenter: parent.horizontalCenter
        y: header.y + header.height + Tokens.spacingMd
        model: [{id: "memory", text: qsTr("Memory")}, {id: "statistics", text: qsTr("Statistics")},
            {id: "files", text: qsTr("Open Files and Ports")}]
        value: root.inspection.tab
        accessibleName: qsTr("Details")
        onPicked: id => root.inspection.tab = id
    }

    // The tab's rows, in a group box as macOS's inspector.
    Rectangle {
        id: box
        x: Tokens.spacingLg
        y: tabs.y + tabs.height + Tokens.spacingSm
        width: parent.width - 2 * Tokens.spacingLg
        height: Math.max(0, footer.y - Tokens.spacingMd - y)
        radius: Tokens.radiusControl
        color: Appearance.colors.groupFill
        border.width: root.hairline
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

        ListView {
            id: rowList
            objectName: "inspectRows"
            anchors.fill: parent
            anchors.margins: Tokens.spacingSm
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Tokens.spacingXs
            model: root.rows
            Accessible.role: Accessible.List
            Accessible.name: tabs.model.find(t => t.id === root.inspection.tab)?.text ?? ""

            header: Text {
                width: rowList.width
                visible: root.filesTab && root.inspection.filesNote !== ""
                height: visible ? implicitHeight + Tokens.spacingSm : 0
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: root.inspection.filesNote
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            delegate: Loader {
                id: line
                required property var modelData
                width: rowList.width
                sourceComponent: root.filesTab ? fileLine : pairLine

                Component {
                    id: pairLine
                    Pair {
                        width: line.width
                        labelWidth: root.rowLabelWidth
                        label: line.modelData.label
                        value: line.modelData.value
                    }
                }

                Component {
                    id: fileLine
                    Item {
                        width: line.width
                        height: fileText.implicitHeight
                        Accessible.role: Accessible.StaticText
                        Accessible.name: fileText.text

                        Text {
                            id: fdText
                            width: Tokens.activityColumnMinWidth
                            horizontalAlignment: Text.AlignRight
                            textFormat: Text.PlainText
                            text: String(line.modelData.fd)
                            color: Appearance.windowSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.features: {"tnum": 1}
                        }

                        Text {
                            id: fileText
                            x: fdText.width + Tokens.spacingSm
                            width: parent.width - x
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            text: line.modelData.text
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }
                    }
                }
            }
        }

        ScrollBar {
            flickable: rowList
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: Tokens.spacingXs
        }
    }

    // AM59: Quit (no Sample button, ADR-0038 h). The pointer is followed by the button's frame, which stays enabled when
    // the button is not: its tooltip says why it is off.
    Item {
        id: footer
        x: Tokens.spacingLg
        width: quitButton.implicitWidth
        height: quitButton.implicitHeight
        y: parent.height - height - Tokens.spacingLg

        Button {
            id: quitButton
            objectName: "inspectQuit"
            push: true
            text: qsTr("Quit")
            enabled: root.inspection.actions.canQuit
            onClicked: sheets.openQuit()
        }

        HoverHandler {
            id: quitHover
        }
    }

    // AM57: another owner's process: Quit is off, and says why.
    Tooltip {
        objectName: "inspectTip"
        text: root.inspection.actions.refusal !== "" ? root.inspection.actions.refusal : qsTr("Quit this process")
        shown: quitHover.hovered
        x: footer.x
        y: footer.y - height - Tokens.spacingXs
        z: 10
    }

    // AM50 to AM56: the sheets, for this process alone.
    ActionSheets {
        id: sheets
        objectName: "inspectSheets"
        actions: root.inspection.actions
        focusBack: quitButton
        z: 20
    }
}
