import QtQuick
import Grassfield.Ui

// A one-line notice above the page (spec SR29): offline ("You're offline. The catalog is from 27 October."), or a catalog
// older than 30 days; and how an operation ended or a lock pacman left (SR19, SR20), with its actions as links after the
// text ([{id, text}]: Try Again, Details…, Close). Read by assistive technologies when it appears.
Rectangle {
    id: root

    property string text: ""
    property var actions: []

    signal acted(string id)

    visible: root.text !== ""
    implicitWidth: glyph.width + label.implicitWidth + links.width + (root.actions.length > 0 ? 4 : 3) * Tokens.storeNoticePadding
    implicitHeight: visible ? Math.max(label.implicitHeight, links.height) + 2 * Tokens.storeNoticePadding : 0
    radius: Tokens.storeNoticeRadius
    // Over the page: the window's colour with a hairline rim, so that it stands out from cards and tiles alike.
    color: Appearance.colors.windowBackground
    border.width: Tokens.storeNoticeRimWidth
    border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity * Tokens.storeNoticeRimContrast)
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
        anchors.right: links.left
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

    Row {
        id: links
        anchors.right: parent.right
        anchors.rightMargin: root.actions.length > 0 ? Tokens.storeNoticePadding : 0
        anchors.verticalCenter: parent.verticalCenter
        spacing: Tokens.storeNoticePadding

        Repeater {
            model: root.actions

            delegate: LinkText {
                required property var modelData
                text: modelData.text
                maximumLineCount: 1
                onActivated: root.acted(modelData.id)
            }
        }
    }
}
