import QtQuick
import Grassfield.Ui

// The soft vertical gradient of a Settings icon tile (macOS: a lighter top over a deeper bottom), in the vivid color.tile
// family: no text sits on a tile and the white glyph holds 3:1 on the lightest point (ADR-0024 amendment 2026-11-03). Use as
// `gradient: TileGradient { name: "blue" }`; an unknown name draws graphite.
Gradient {
    id: root

    // blue, green, red, pink, purple, cyan, orange, graphite or black.
    property string name: "graphite"
    readonly property var tiles: Tokens.colorTile
    readonly property bool known: root.tiles[root.name] !== undefined
    // The dark appearance may have its own pair (black: blackTopDark, blackDark), so the tile reads off the dark panel.
    readonly property string suffix: Appearance.dark && root.tiles[root.name + "Dark"] !== undefined ? "Dark" : ""

    GradientStop {
        position: 0.0
        color: root.known ? root.tiles[root.name + "Top" + root.suffix] : root.tiles.graphiteTop
    }
    GradientStop {
        position: 1.0
        color: root.known ? root.tiles[root.name + root.suffix] : root.tiles.graphite
    }
}
