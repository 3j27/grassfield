import QtQuick
import "WindowActions.js" as Actions

// The toolbar row of a Grassfield app window (ADR-0015): the window lights, the window title and the app's toolbar items
// in one bar, as in a macOS toolbar window. The app declares the style and places its items; it never draws or wires the
// lights. Place it at the top of the window; it takes the width of its parent.
//
// style "unified": a 52-pt row, the lights' first centre at 25.75 / 25.75, the title left-aligned and bold after the
//   leading items. A window whose sidebar holds the lights puts one toolbar over the sidebar (showControls, no title,
//   no items) and one over the content (showControls false).
// style "titlebar": a 32-pt row with the lights and a centred title (Get Info, Customize Folder).
//
// Items: `leading` (default property, after the lights and before the title) and `trailing` (right-aligned). Empty
// space is the window's drag area: a drag starts the compositor's interactive move (xdg_toplevel.move) and a double-click
// does what `doubleClickAction` says (`windows.titlebarDoubleClick`: zoom, minimize or none).
Item {
    id: root

    // The QtQuick Window the toolbar belongs to.
    property var window: null
    // "unified" or "titlebar".
    property string style: "unified"
    property string title: ""
    property bool showTitle: true
    // Draw the three lights here (false where another toolbar over the sidebar holds them).
    property bool showControls: true
    // windows.titlebarDoubleClick of grassfield.json: "zoom" (default), "minimize" or "none".
    property string doubleClickAction: "zoom"
    property bool canMinimize: true
    property string accessibleName: qsTr("Toolbar")
    default property alias leading: leadingRow.data
    property alias trailing: trailingRow.data

    readonly property bool titlebarStyle: root.style === "titlebar"
    readonly property alias controls: lights
    // Left edge of the leading items: after the lights, or the item inset where the lights are elsewhere.
    readonly property real contentStart: root.showControls ? Math.max(lights.contentStart, Tokens.windowItemsInset) : Tokens.windowItemsInset
    // Where the title may start and end (the host reads them to place extra content).
    readonly property real titleStart: leadingRow.x + (leadingRow.children.length > 0 ? leadingRow.width + Tokens.windowItemsGap : 0)
    readonly property real titleEnd: trailingRow.children.length > 0 ? trailingRow.x - Tokens.windowItemsGap : root.width - Tokens.windowItemsInset

    // What a double-click on empty space did last (tests read it; "" before any).
    property string lastDoubleClick: ""

    implicitHeight: root.titlebarStyle ? Tokens.windowTitlebarHeight : Tokens.windowUnifiedHeight
    height: implicitHeight
    Accessible.role: Accessible.ToolBar
    Accessible.name: root.accessibleName

    // The double-click, also callable by a host (a keyboard route to the same action).
    function doubleClicked(): void {
        root.lastDoubleClick = Actions.doubleClick(root.window, root.doubleClickAction, root.canMinimize);
    }

    // Drag and double-click on the empty space: behind every item, so a press on a control never moves the window.
    Item {
        id: dragArea
        anchors.fill: parent
        z: -1

        DragHandler {
            target: null
            acceptedButtons: Qt.LeftButton
            // The threshold is Qt's own drag distance; the compositor then follows the pointer (ADR-0015, step 3).
            onActiveChanged: {
                if (active && root.window)
                    root.window.startSystemMove();
            }
        }

        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: root.doubleClicked()
        }
    }

    WindowControls {
        id: lights
        visible: root.showControls && !lights.fullScreen
        window: root.window
        style: root.style
        canMinimize: root.canMinimize
    }

    Row {
        id: leadingRow
        x: root.contentStart
        anchors.verticalCenter: parent.verticalCenter
        spacing: Tokens.windowItemsGap
    }

    Text {
        id: titleText
        textFormat: Text.PlainText
        visible: root.showTitle
        anchors.verticalCenter: parent.verticalCenter
        x: root.titlebarStyle ? Math.max(root.titleStart, (root.width - Math.min(titleText.implicitWidth, root.titleEnd - root.titleStart)) / 2) : root.titleStart
        width: Math.max(0, Math.min(titleText.implicitWidth, root.titleEnd - titleText.x))
        text: root.title
        elide: Text.ElideRight
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: root.titlebarStyle ? Tokens.typographyBodySize : Tokens.windowTitleSize
        font.weight: Tokens.typographyMenuBoldWeight
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    Row {
        id: trailingRow
        anchors.right: parent.right
        anchors.rightMargin: Tokens.windowItemsInset
        anchors.verticalCenter: parent.verticalCenter
        spacing: Tokens.windowItemsGap
    }
}
