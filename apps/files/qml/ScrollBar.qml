import QtQuick
import Grassfield.Ui

// Overlay scroll bar for a Flickable (no Qt Quick Controls in Grassfield apps): a draggable thumb that
// shows while the view moves or the pointer is over it.
Item {
    id: root

    required property Flickable flickable

    readonly property real ratio: flickable.visibleArea.heightRatio
    readonly property bool needed: ratio < 1 && flickable.contentHeight > 0
    readonly property real thumbLength: Math.max(Tokens.filesScrollbarMinLength, root.height * root.ratio)

    width: Tokens.filesScrollbarWidth + Tokens.spacingXs
    visible: needed
    opacity: flickable.moving || area.containsMouse || area.pressed ? 1 : Tokens.filesScrollbarIdleOpacity
    Accessible.role: Accessible.ScrollBar
    Accessible.name: qsTr("Scroll bar")

    Rectangle {
        id: thumb
        x: Tokens.spacingXs / 2
        width: Tokens.filesScrollbarWidth
        radius: width / 2
        height: root.thumbLength
        y: root.flickable.visibleArea.yPosition / Math.max(1e-6, 1 - root.ratio) * (root.height - root.thumbLength)
        color: Appearance.withAlpha(Appearance.colors.text, area.pressed ? Tokens.filesScrollbarPressedOpacity : Tokens.filesScrollbarThumbOpacity)
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        property real grabOffset: 0
        function scrollTo(y: real): void {
            const f = root.flickable;
            const span = root.height - root.thumbLength;
            const pos = span > 0 ? Math.max(0, Math.min(1, (y - grabOffset) / span)) : 0;
            f.contentY = f.originY + pos * (f.contentHeight - f.height);
        }
        onPressed: mouse => {
            grabOffset = mouse.y >= thumb.y && mouse.y <= thumb.y + thumb.height ? mouse.y - thumb.y : root.thumbLength / 2;
            scrollTo(mouse.y);
        }
        onPositionChanged: mouse => {
            if (pressed)
                scrollTo(mouse.y);
        }
    }
}
