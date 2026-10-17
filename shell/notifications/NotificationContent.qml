pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Icon, title, relative time, sanitized body and action buttons of one notification. Used by
// banners and by the Notification Center rows. Pure presentation: actions are reported through
// signals (the host decides what they do).
Item {
    id: root

    // Model row fields (see Notifications.rowOf). live: the sender still holds the notification.
    property string summary: ""
    property string appName: ""
    property int urgency: 1
    property string actionsJson: "[]"
    property bool live: false
    property int maxBodyLines: Tokens.notificationBannerBodyLines
    property string body: ""
    property string timeText: ""
    property string iconSource: ""
    // "default" is the click action, never a button. Dead and restored entries have none.
    readonly property var buttons: live ? JSON.parse(actionsJson).filter(a => a.id !== "default" && a.id !== "") : []
    property bool moreOpen: false
    // Space kept free at the right of the title row (the Center's remove button).
    property real trailingReserve: 0

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
            size: Tokens.menuIconSize + Tokens.notificationIconGlyphExtra
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
                anchors.rightMargin: root.trailingReserve
                text: root.timeText
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                font.weight: Tokens.typographySmallWeight
            }

            Text {
                id: title
                width: parent.width - stamp.implicitWidth - Tokens.spacingSm - root.trailingReserve
                text: root.summary !== "" ? root.summary : root.appName
                textFormat: Text.PlainText
                color: root.urgency === 2 ? Appearance.colors.danger : Appearance.colors.text
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

        // No delegate exists unless the notification is live and has buttons: a sender's labels
        // never instantiate for dead, expired or restored entries.
        Loader {
            width: parent.width
            active: root.buttons.length > 0
            visible: active
            sourceComponent: actionRow
        }
    }

    Component {
        id: actionRow

        Flow {
            id: actions
            width: root.width - iconTile.width - Tokens.spacingSm
            spacing: Tokens.spacingSm
            topPadding: Tokens.spacingXs

            Repeater {
                model: root.buttons.slice(0, root.moreOpen ? root.buttons.length : Tokens.notificationMaxActions)

                delegate: Button {
                    required property var modelData
                    width: Math.min(implicitWidth, actions.width)
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
