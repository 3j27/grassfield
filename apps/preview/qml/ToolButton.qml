import QtQuick
import Grassfield.Ui

// Toolbar button: the shared Button, compact, dimmed when disabled. `label` is the accessible name
// when the visible text is only a symbol.
Button {
    id: root

    property string label: ""

    width: root.text.length <= 1 ? Tokens.previewToolbarButtonSize : Math.max(Tokens.previewToolbarButtonSize, implicitWidth - 2 * Tokens.spacingSm)
    height: Tokens.previewToolbarButtonSize
    opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
    Accessible.name: root.label !== "" ? root.label : root.text
    Accessible.description: root.label !== "" ? root.text : ""
}
