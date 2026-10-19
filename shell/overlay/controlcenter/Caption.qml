import QtQuick
import Grassfield.Ui

// Secondary text of the Control Center (plain text, see Label).
Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: Appearance.colors.textSecondary
    font.family: Appearance.fontFamily
    font.pixelSize: Tokens.typographyCaptionSize
    font.weight: Tokens.typographyMenuWeight
}
