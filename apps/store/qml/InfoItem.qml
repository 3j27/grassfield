import QtQuick
import Grassfield.Ui

// One fact of a product page's Information (spec SR11): its label in small grey text over its value; a value that is a
// link (Homepage, Bug tracker) is an underlined host the browser opens on click (https only, StoreBackend::openLink).
Column {
    id: root

    property string label: ""
    property string value: ""
    property string link: ""

    signal linkActivated(string url)

    spacing: Tokens.storeInfoLineGap
    Accessible.role: Accessible.StaticText
    Accessible.name: root.label + ": " + root.value
    Accessible.ignored: root.link !== ""

    Text {
        width: root.width
        textFormat: Text.PlainText
        text: root.label
        elide: Text.ElideRight
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeInfoLabelSize
        font.letterSpacing: Appearance.tracking(Tokens.storeInfoLabelSize)
    }

    Text {
        width: root.width
        visible: root.link === ""
        textFormat: Text.PlainText
        text: root.value
        wrapMode: Text.Wrap
        maximumLineCount: 6
        elide: Text.ElideRight
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeInfoValueSize
        font.letterSpacing: Appearance.tracking(Tokens.storeInfoValueSize)
    }

    LinkText {
        visible: root.link !== ""
        width: Math.min(implicitWidth, root.width)
        text: root.value
        target: root.link
        maximumLineCount: 1
        onActivated: root.linkActivated(root.link)
    }
}
