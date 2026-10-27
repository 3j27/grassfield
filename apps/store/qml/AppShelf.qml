import QtQuick
import Grassfield.Ui

// A row block (spec SR4): its title, then its apps in columns of lockups (icon, name, summary, source, button).
Column {
    id: root

    property string title: ""
    property var apps: []

    signal opened(string id)

    // The title line's height (0 without a title): a link beside it is centred on it.
    readonly property real titleHeight: heading.visible ? heading.height : 0

    spacing: Tokens.storeShelfTitleGap

    Text {
        id: heading
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
