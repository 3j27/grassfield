import QtQuick
import Grassfield.Ui

// Body text of the Control Center. Always plain text: strings may come from the network or devices.
Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: Appearance.colors.text
    font.family: Appearance.fontFamily
    font.pixelSize: Tokens.typographyBodySize
    font.weight: Tokens.typographyMenuWeight
}
