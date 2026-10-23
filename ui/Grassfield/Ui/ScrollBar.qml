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

    implicitWidth: orientation === Qt.Vertical ? Tokens.controlScrollbarWidth + Tokens.spacingXs : 0
    implicitHeight: orientation === Qt.Horizontal ? Tokens.controlScrollbarWidth + Tokens.spacingXs : 0
    visible: standalone ? (root.flickable.visibleArea.heightRatio < 1 && root.flickable.contentHeight > 0) : policy !== T.ScrollBar.AlwaysOff && size < 1
    hoverEnabled: true
    focusPolicy: Qt.NoFocus
    minimumSize: root.thumbMin / Math.max(1, orientation === Qt.Vertical ? height : width)
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

    contentItem: Rectangle {
        implicitWidth: Tokens.controlScrollbarWidth
        implicitHeight: Tokens.controlScrollbarWidth
        radius: Math.min(width, height) / 2
        color: Appearance.withAlpha(Appearance.colors.text, root.pressed ? Tokens.controlScrollbarPressedOpacity : Tokens.controlScrollbarThumbOpacity)
        opacity: (root.standalone ? root.flickable.moving : root.active) || root.hovered || root.pressed ? 1 : Tokens.controlScrollbarIdleOpacity
    }

    background: Item {}
}
