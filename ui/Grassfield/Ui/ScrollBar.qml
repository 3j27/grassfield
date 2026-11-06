import QtQuick
import QtQuick.Templates as T

// Overlay scroll bar (QtQuick.Templates ScrollBar): a thin draggable thumb that shows while the view moves or the pointer
// is over it. Two ways to use it: attached, `ScrollBar.vertical: ScrollBar {}` on a Flickable or ListView (the template
// feeds size and position), or standalone beside a view with `flickable: view` (this type feeds them itself, vertical).
T.ScrollBar {
    id: root

    // Standalone use: the view this bar scrolls (null when attached through ScrollBar.vertical / horizontal).
    property Flickable flickable: null

    readonly property bool standalone: root.flickable !== null
    readonly property real thumbMin: Tokens.controlScrollbarMinLength

    // The thumb (scrollbarWidth) sits scrollbarInset inside its lane, clear of the view's edge and of its corners (macOS 27;
    // UI audit 2026-11-05 U31: it filled the 10-pt lane, flush with the edge).
    implicitWidth: orientation === Qt.Vertical ? Tokens.controlScrollbarWidth + 2 * Tokens.controlScrollbarInset : 0
    implicitHeight: orientation === Qt.Horizontal ? Tokens.controlScrollbarWidth + 2 * Tokens.controlScrollbarInset : 0
    padding: Tokens.controlScrollbarInset
    visible: standalone ? (root.flickable.visibleArea.heightRatio < 1 && root.flickable.contentHeight > 0) : policy !== T.ScrollBar.AlwaysOff && size < 1
    hoverEnabled: true
    focusPolicy: Qt.NoFocus
    minimumSize: root.thumbMin / Math.max(1, orientation === Qt.Vertical ? availableHeight : availableWidth)
    Accessible.role: Accessible.ScrollBar
    Accessible.name: qsTr("Scroll bar")

    // Standalone: follow the view and move it when the thumb is dragged.
    Binding {
        target: root
        property: "size"
        value: root.flickable ? root.flickable.visibleArea.heightRatio : 1
        when: root.standalone
    }

    Binding {
        target: root
        property: "position"
        value: root.flickable ? root.flickable.visibleArea.yPosition : 0
        when: root.standalone && !root.pressed
    }

    onPositionChanged: {
        if (root.standalone && root.pressed) {
            const f = root.flickable;
            f.contentY = f.originY + Math.min(1, root.position / Math.max(1e-6, 1 - root.size)) * Math.max(0, f.contentHeight - f.height);
        }
    }

    // Shown while the view moves, under the pointer or while dragged; it stays a moment after that, then fades out (macOS 27
    // overlay scroll bars: nothing is drawn over a still view).
    readonly property bool showing: (root.standalone ? root.flickable.moving : root.active) || root.hovered || root.pressed
    property bool lingering: false
    onShowingChanged: {
        if (root.showing) {
            hideTimer.stop();
        } else {
            root.lingering = true;
            hideTimer.restart();
        }
    }

    Timer {
        id: hideTimer
        interval: Tokens.controlScrollbarHideDelayMs
        onTriggered: root.lingering = false
    }

    contentItem: Rectangle {
        implicitWidth: Tokens.controlScrollbarWidth
        implicitHeight: Tokens.controlScrollbarWidth
        radius: Math.min(width, height) / 2
        color: Appearance.withAlpha(Appearance.colors.text, root.pressed ? Tokens.controlScrollbarPressedOpacity : Tokens.controlScrollbarThumbOpacity)
        opacity: root.showing || root.lingering ? 1 : Tokens.controlScrollbarIdleOpacity

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionNormal)
            }
        }
    }

    background: Item {}
}
