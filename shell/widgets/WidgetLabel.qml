import QtQuick
import Grassfield.Ui

// Plain text for widgets: PlainText, shell font, text color, elided. Set `size`, not font.pixelSize: the family follows it
// (Inter Display from 20 px, Appearance.fontFamilyFor).
Text {
    property real size: Tokens.typographyBodySize

    textFormat: Text.PlainText
    color: Appearance.colors.text
    font.family: Appearance.fontFamilyFor(size)
    font.pixelSize: size
    font.weight: Tokens.typographyMenuWeight
    elide: Text.ElideRight
}
