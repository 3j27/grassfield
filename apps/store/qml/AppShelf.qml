import QtQuick
import Grassfield.Ui

// A row block (spec SR4): its title, then its apps in columns of lockups (icon, name, summary, source, button).
Column {
    id: root

    property string title: ""
    property var apps: []

    signal opened(string id)

    spacing: Tokens.storeShelfTitleGap

    Text {
        width: root.width
        visible: root.title !== ""
        textFormat: Text.PlainText
        text: root.title
        elide: Text.ElideRight
        color: Appearance.colors.text
        font.family: Appearance.fontFamilyFor(Tokens.storeShelfTitleSize)
        font.pixelSize: Tokens.storeShelfTitleSize
        font.weight: Tokens.typographyMenuBoldWeight
        font.letterSpacing: Appearance.trackingFor(Tokens.storeShelfTitleSize)
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    AppGrid {
        width: root.width
        apps: root.apps
        onOpened: id => root.opened(id)
    }
}
