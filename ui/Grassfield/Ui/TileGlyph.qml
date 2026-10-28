pragma ComponentBehavior: Bound
import QtQuick

// A tiling glyph (docs/specs/tiling.md TL23, TL25): a miniature screen, an outline with the zones of a place or an arrangement
// inside it. `zones` are [x, y, w, h] in twelfths of the screen, as in the tiling.layout* tokens; the zone `own` (the window
// that asks) is drawn in full, the others light (parity row M19); own -1 draws every zone in full. Sizes follow the
// tiling.glyph* tokens at the popover size and scale with `width` (a menu row draws it at the icon size).
Item {
    id: root

    property var zones: []
    property int own: 0
    property color color: Appearance.colors.text

    readonly property real ratio: width / Tokens.tilingGlyphWidth
    readonly property real stroke: Math.max(1, Tokens.tilingGlyphStroke * root.ratio)
    readonly property real inset: Tokens.tilingGlyphInset * root.ratio
    readonly property real gap: Tokens.tilingGlyphGap * root.ratio
    // The area inside the outline the zones share.
    readonly property real innerX: root.stroke + root.inset
    readonly property real innerW: root.width - 2 * root.innerX
    readonly property real innerH: root.height - 2 * root.innerX

    implicitWidth: Tokens.tilingGlyphWidth
    implicitHeight: Math.round(root.width * Tokens.tilingGlyphHeight / Tokens.tilingGlyphWidth)
    width: implicitWidth
    height: implicitHeight
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: root.stroke
        border.color: root.color
        radius: Tokens.tilingGlyphRadius * root.ratio
    }

    Repeater {
        model: root.zones

        Rectangle {
            id: zone

            required property var modelData
            required property int index

            // A zone keeps half the gap on each side it shares with another zone; on the outline's side it keeps the inset.
            readonly property real x0: root.innerW * zone.modelData[0] / 12 + (zone.modelData[0] > 0 ? root.gap / 2 : 0)
            readonly property real x1: root.innerW * (zone.modelData[0] + zone.modelData[2]) / 12 - (zone.modelData[0] + zone.modelData[2] < 12 ? root.gap / 2 : 0)
            readonly property real y0: root.innerH * zone.modelData[1] / 12 + (zone.modelData[1] > 0 ? root.gap / 2 : 0)
            readonly property real y1: root.innerH * (zone.modelData[1] + zone.modelData[3]) / 12 - (zone.modelData[1] + zone.modelData[3] < 12 ? root.gap / 2 : 0)

            x: root.innerX + zone.x0
            y: root.innerX + zone.y0
            width: Math.max(0, zone.x1 - zone.x0)
            height: Math.max(0, zone.y1 - zone.y0)
            radius: Math.max(0, Tokens.tilingGlyphRadius * root.ratio - root.innerX)
            color: root.own < 0 || zone.index === root.own ? root.color : Appearance.withAlpha(root.color, Tokens.tilingGlyphOtherOpacity)
        }
    }
}
