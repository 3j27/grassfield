import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// Where an app comes from (spec SR5, ADR-0037: the source on every card, list item and product page): one line of
// secondary text, "Arch Linux · extra", "Omarchy setup", "Web app"…
Text {
    id: root

    property string kind: ""
    property string repo: ""

    textFormat: Text.PlainText
    text: Store.sourceLabel(root.kind, root.repo)
    elide: Text.ElideRight
    color: Appearance.windowSecondary
    font.family: Appearance.fontFamily
    font.pixelSize: Tokens.storeBadgeSize
    font.letterSpacing: Appearance.tracking(Tokens.storeBadgeSize)
    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("Source: %1").arg(root.text)
}
