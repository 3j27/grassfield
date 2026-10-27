import QtQuick
import Grassfield.Ui

// A one-line notice above the page (spec SR29): offline ("You're offline. The catalog is from 27 October."), or a catalog
// older than 30 days. Read by assistive technologies when it appears.
Rectangle {
    id: root

    property string text: ""

    visible: root.text !== ""
    implicitWidth: glyph.width + label.implicitWidth + 3 * Tokens.storeNoticePadding
    implicitHeight: visible ? label.implicitHeight + 2 * Tokens.storeNoticePadding : 0
    radius: Tokens.storeNoticeRadius
    // Over the page: the window's colour with a hairline rim, so that it stands out from cards and tiles alike.
    color: Appearance.colors.windowBackground
    border.width: 1
    border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity * 2)
    Accessible.role: Accessible.AlertMessage
    Accessible.name: root.text

    Icon {
        id: glyph
        x: Tokens.storeNoticePadding
        anchors.verticalCenter: parent.verticalCenter
        name: "info"
        size: Tokens.storeNoticeIconSize
        color: Appearance.windowSecondary
    }

    Text {
        id: label
        anchors.left: glyph.right
        anchors.leftMargin: Tokens.storeNoticePadding
        anchors.right: parent.right
        anchors.rightMargin: Tokens.storeNoticePadding
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.text
        wrapMode: Text.Wrap
        maximumLineCount: 3
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBadgeSize
    }
}
