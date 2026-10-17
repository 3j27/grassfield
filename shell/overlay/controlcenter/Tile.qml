import QtQuick
import Grassfield.Ui

// Rounded card of the Control Center; children are laid out in a column with the card padding.
Rectangle {
    id: root

    default property alias body: inner.data
    property int padding: Tokens.spacingMd

    width: parent ? parent.width : implicitWidth
    implicitHeight: inner.implicitHeight + 2 * padding
    radius: Tokens.radiusMenu
    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2)

    Column {
        id: inner
        x: root.padding
        y: root.padding
        width: root.width - 2 * root.padding
        spacing: Tokens.spacingSm
    }
}
