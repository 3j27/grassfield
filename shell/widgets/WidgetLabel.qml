import QtQuick
import Grassfield.Ui

// Plain text for widgets: PlainText, shell font, text color, elided.
Text {
    textFormat: Text.PlainText
    color: Appearance.colors.text
    font.family: Appearance.fontFamily
    font.pixelSize: Tokens.typographyBodySize
    font.weight: Tokens.typographyMenuWeight
    elide: Text.ElideRight
}
