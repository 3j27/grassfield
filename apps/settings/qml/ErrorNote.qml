import QtQuick
import Grassfield.Ui

// One short line under a list when the last action failed, with the tool's own reason (SystemService.errors).
Text {
    id: root

    // The tag of the page's actions ("wifi.act"); the line shows what SystemService recorded for it.
    required property var system
    required property string tag
    readonly property string reason: root.system ? (root.system.errors[root.tag] ?? "") : ""

    textFormat: Text.PlainText
    // A hidden note takes no room in the page's column (a height bound to the visibility loops through the wrapped text's
    // implicit height once the page is shown).
    visible: root.reason !== ""
    width: parent ? parent.width : implicitWidth
    leftPadding: Tokens.spacingMd
    rightPadding: Tokens.spacingMd
    wrapMode: Text.Wrap
    text: root.reason === "-" ? qsTr("The action failed.") : qsTr("The action failed: %1").arg(root.reason)
    color: Appearance.colors.textSecondary
    font.family: Appearance.fontFamily
    font.pixelSize: Tokens.typographyCaptionSize
    Accessible.role: Accessible.StaticText
    Accessible.name: text
}
