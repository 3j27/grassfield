import QtQuick
import Grassfield.Ui

// Line glyphs of the Preview toolbar and sidebar: Preview's own monochrome SVGs (24 x 24 grid, stroke 1.75, round caps,
// the style of the Grassfield symbolic icons; the design system has no zoom, rotate or info icons yet), recoloured by
// the shared Icon. `kind` is the file name in icons/.
Icon {
    property string kind: "info"

    name: kind
    directory: Qt.resolvedUrl("icons/")
    size: Tokens.previewToolbarIconSize
}
