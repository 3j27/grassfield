import QtQuick
import Grassfield.Ui

// A page's large title (macOS 27 Discover: bold, its cap top 67 pt from the window's top, 40 pt in from the sidebar).
Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: Appearance.colors.text
    font.family: Appearance.fontFamilyFor(Tokens.storePageTitleSize)
    font.pixelSize: Tokens.storePageTitleSize
    font.weight: Tokens.typographyMenuBoldWeight
    font.letterSpacing: Appearance.trackingFor(Tokens.storePageTitleSize)
    Accessible.role: Accessible.Heading
    Accessible.name: text
}
