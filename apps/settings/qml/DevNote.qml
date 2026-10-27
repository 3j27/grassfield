import QtQuick
import Grassfield.Ui

// Shown by the system sections after an action was suppressed by the dev guard (SystemService.qml).
Text {
    required property var system

    textFormat: Text.PlainText
    visible: system ? system.suppressedNote : false
    width: parent ? parent.width : implicitWidth
    // Each page's Column skips it while it is hidden (a height bound to `visible` was a binding loop there).
    height: implicitHeight
    leftPadding: Tokens.spacingMd
    text: qsTr("dev: not applied")
    color: Appearance.colors.textSecondary
    font.family: Appearance.fontFamily
    font.pixelSize: Tokens.typographyCaptionSize
    Accessible.role: Accessible.StaticText
    Accessible.name: text
}
