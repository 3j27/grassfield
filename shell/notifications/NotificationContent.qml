pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Icon, title, relative time, sanitized body and action buttons of one notification. Used by
// banners and by the Notification Center rows. Pure presentation: actions are reported through
// signals (the host decides what they do).
Item {
    id: root

    // History entry (see History.js); live: the sender still holds the notification.
    required property var entry
    property int maxBodyLines: Tokens.notificationBannerBodyLines
    property string body: ""
    property string timeText: ""
    property string iconSource: ""
    readonly property bool live: entry.nid >= 0
    // "default" is the click action, never a button.
    readonly property var buttons: (entry.actions || []).filter(a => a.id !== "default" && a.id !== "")
    property bool moreOpen: false

    signal actionTriggered(string actionId)

    implicitWidth: Tokens.notificationBannerWidth
    implicitHeight: Math.max(Tokens.notificationBannerIconSize, column.implicitHeight)

    // Icon tile: image/app icon, or a bell on a neutral tile.
    Item {
        id: iconTile
        width: Tokens.notificationBannerIconSize
        height: Tokens.notificationBannerIconSize

        Rectangle {
            anchors.fill: parent
            radius: Tokens.radiusDockIcon
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            visible: appImage.status !== Image.Ready
        }

        Icon {
            anchors.centerIn: parent
            size: Tokens.menuIconSize + 4
            name: "bell"
            visible: appImage.status !== Image.Ready
        }

        Image {
            id: appImage
            anchors.fill: parent
            source: root.iconSource
            // Images are limited to 256 px (N9).
            sourceSize: Qt.size(Tokens.notificationImageMax, Tokens.notificationImageMax)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            mipmap: true
        }
    }

    Column {
        id: column
        x: iconTile.width + Tokens.spacingSm
        width: root.width - x
        spacing: Tokens.spacingXs

        Item {
            width: parent.width
            height: title.implicitHeight

            Text {
                textFormat: Text.PlainText
                id: stamp
                anchors.right: parent.right
                text: root.timeText
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                font.weight: Tokens.typographySmallWeight
            }

            Text {
                id: title
                width: parent.width - stamp.implicitWidth - Tokens.spacingSm
                text: root.entry.summary !== "" ? root.entry.summary : root.entry.appName
                textFormat: Text.PlainText
                color: root.entry.urgency === 2 ? Appearance.colors.danger : Appearance.colors.text
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyMenuBoldWeight
            }
        }

        Text {
            width: parent.width
            visible: text !== ""
            text: root.body
            textFormat: Text.StyledText
            color: Appearance.colors.text
            opacity: Tokens.materialBodyOpacity
            wrapMode: Text.Wrap
            maximumLineCount: root.maxBodyLines
            elide: Text.ElideRight
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyMenuWeight
        }

        Flow {
            width: parent.width
            spacing: Tokens.spacingSm
            visible: root.live && root.buttons.length > 0
            topPadding: Tokens.spacingXs

            Repeater {
                model: root.buttons.slice(0, root.moreOpen ? root.buttons.length : Tokens.notificationMaxActions)

                delegate: Button {
                    required property var modelData
                    text: modelData.text
                    onClicked: root.actionTriggered(modelData.id)
                }
            }

            Button {
                visible: !root.moreOpen && root.buttons.length > Tokens.notificationMaxActions
                text: qsTr("More")
                onClicked: root.moreOpen = true
            }
        }
    }
}
