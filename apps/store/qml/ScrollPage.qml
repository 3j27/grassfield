import QtQuick
import Grassfield.Ui

// A page of the Store: its large title where macOS 27 puts Discover's (cap top 67 pt from the window's top), then its
// content 40 pt in from both edges, scrolled under the toolbar (a fade of the window's colour there once it moves). The
// keys scroll it: Page Up and Down, Home and End, and the arrows when nothing inside takes them.
FocusScope {
    id: root

    property string title: ""
    property alias scroll: flick.contentY
    // A scroll to come back to (Back, Forward, a new snapshot): applied as soon as the page is tall enough for it.
    property real pendingScroll: -1

    function restoreScroll(y: real): void {
        root.pendingScroll = y;
        root.applyPending();
    }

    function applyPending(): void {
        if (root.pendingScroll < 0)
            return;
        const max = Math.max(0, flick.contentHeight - flick.height);
        flick.contentY = Math.min(root.pendingScroll, max);
        if (max >= root.pendingScroll)
            root.pendingScroll = -1;
    }
    property alias flickable: flick
    default property alias content: column.data
    readonly property real contentWidth: Math.max(0, root.width - 2 * Tokens.storeContentMargin)
    property real spacing: Tokens.storeBlockGap
    // Where the content starts: under the large title (the hero's top in Discover), or higher on a page without one.
    property real headerHeight: Tokens.storeHeroTop

    Keys.onPressed: event => {
        const page = flick.height - Tokens.windowUnifiedHeight;
        const max = Math.max(0, flick.contentHeight - flick.height);
        let y = null;
        if (event.key === Qt.Key_PageDown || (event.key === Qt.Key_Space && !(event.modifiers & Qt.ShiftModifier)))
            y = flick.contentY + page;
        else if (event.key === Qt.Key_PageUp || (event.key === Qt.Key_Space && (event.modifiers & Qt.ShiftModifier)))
            y = flick.contentY - page;
        else if (event.key === Qt.Key_Down)
            y = flick.contentY + Tokens.storeKeyScrollStep;
        else if (event.key === Qt.Key_Up)
            y = flick.contentY - Tokens.storeKeyScrollStep;
        else if (event.key === Qt.Key_Home)
            y = 0;
        else if (event.key === Qt.Key_End)
            y = max;
        if (y !== null) {
            flick.contentY = Math.max(0, Math.min(max, y));
            event.accepted = true;
        }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: header.height + column.implicitHeight + Tokens.storePageBottom
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        onContentHeightChanged: root.applyPending()
        // A scroll by the user wins over one still waiting.
        onMovementStarted: root.pendingScroll = -1

        ScrollBar.vertical: ScrollBar {}

        Item {
            id: header
            width: flick.width
            height: root.headerHeight

            PageTitle {
                visible: root.title !== ""
                x: Tokens.storeContentMargin + Tokens.storePageTitleInset
                y: Tokens.storePageTitleBaseline - baselineOffset
                width: root.contentWidth
                text: root.title
            }
        }

        Column {
            id: column
            x: Tokens.storeContentMargin
            y: header.height
            width: root.contentWidth
            spacing: root.spacing
        }
    }

    // macOS 27's scroll edge under the toolbar: the window's colour fading out over what scrolls beneath.
    Rectangle {
        width: parent.width
        height: Tokens.windowUnifiedHeight
        visible: flick.contentY > 0
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Appearance.colors.windowBackground
            }
            GradientStop {
                position: 1
                color: Appearance.withAlpha(Appearance.colors.windowBackground, 0)
            }
        }
    }
}
