import QtQuick
import Grassfield.Ui

// A heading inside a page (What's New, Information, an Installed group).
Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: Appearance.colors.text
    font.family: Appearance.fontFamilyFor(Tokens.storeShelfTitleSize)
    font.pixelSize: Tokens.storeShelfTitleSize
    font.weight: Tokens.typographyMenuBoldWeight
    font.letterSpacing: Appearance.trackingFor(Tokens.storeShelfTitleSize)
    Accessible.role: Accessible.Heading
    Accessible.name: text
}
