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
    // The set of focusable action buttons changed (the sender's actions went away, More revealed the rest): the Center's focus
    // resolver (NotificationList.resolveFocus) re-checks where the keyboard focus is.
    signal controlsChanged
    // The Flow of action buttons (null unless the entry is live and has buttons).
    readonly property var actionFlow: actionLoader.item

    // The focusable items of this content in Tab order, usable or not: {role: "action:<id>" or "more", item}.
    function focusItems(): var {
        const out = [];
        const flow = root.actionFlow;
        if (!flow)
            return out;
        for (let i = 0; i < flow.repeater.count; i++) {
            const b = flow.repeater.itemAt(i);
            if (b)
                out.push({role: "action:" + b.modelData.id, item: b});
        }
        out.push({role: "more", item: flow.moreButton});
        return out;
    }

    implicitWidth: Tokens.notificationBannerWidth
    implicitHeight: Math.max(Tokens.notificationBannerIconSize, column.implicitHeight)

    // Icon tile: image/app icon, or a bell on a neutral tile.
    Item {
        id: iconTile
        x: Tokens.notificationIconInset
        // Centred on the whole card, as in the reference (also beside a five-line body).
        y: Math.max(0, (root.implicitHeight - height) / 2)
        width: Tokens.notificationBannerIconSize
        height: Tokens.notificationBannerIconSize

        Rectangle {
            anchors.fill: parent
            // An app icon's corner at its size, no longer the Dock's (ADR-0039 step 13, G5).
            radius: Tokens.notificationIconRadius
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
        x: iconTile.x + iconTile.width + Tokens.notificationTextGap
        width: root.width - x
        spacing: Tokens.notificationLineGap

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
            id: actionLoader
            width: parent.width
            active: root.buttons.length > 0
            visible: active
            sourceComponent: actionRow
            onItemChanged: root.controlsChanged()
        }
    }

    Component {
        id: actionRow

        Flow {
            id: actions
            width: column.width
            spacing: Tokens.spacingSm
            topPadding: Tokens.spacingXs
            readonly property Repeater repeater: rep
            readonly property Item moreButton: more

            // macOS: equal-width capsules spanning the card, 22 tall.
            readonly property int shownCount: rep.count + (more.visible ? 1 : 0)
            readonly property real equalWidth: shownCount > 0 ? (width - (shownCount - 1) * spacing) / shownCount : width

            Repeater {
                id: rep
                onItemAdded: root.controlsChanged()
                onItemRemoved: root.controlsChanged()
                model: root.buttons.slice(0, root.moreOpen ? root.buttons.length : Tokens.notificationMaxActions)

                delegate: Button {
                    required property var modelData
                    width: actions.equalWidth
                    height: Tokens.notificationActionHeight
                    capsule: true
                    text: modelData.text
                    onClicked: root.actionTriggered(modelData.id)
                }
            }

            Button {
                id: more
                visible: !root.moreOpen && root.buttons.length > Tokens.notificationMaxActions
                onVisibleChanged: root.controlsChanged()
                width: actions.equalWidth
                height: Tokens.notificationActionHeight
                capsule: true
                text: qsTr("More")
                onClicked: root.moreOpen = true
            }
        }
    }
}
