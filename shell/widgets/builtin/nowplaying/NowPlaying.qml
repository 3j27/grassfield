pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import qs.widgets
import "../../ArtUrl.js" as ArtUrl

// Now Playing widget: the active MPRIS player's track (small: art and title; medium: art, title,
// artist and transport). Says "Not Playing" when no player runs or nothing is loaded. Transport
// buttons act on the owner's real player, so a development session (GRASSFIELD_DEV=1) disables them.
WidgetBase {
    id: root

    readonly property bool hasTrack: Media.available && Media.title !== ""
    readonly property bool transportEnabled: Media.available && !devSession

    Accessible.role: Accessible.StaticText
    Accessible.name: hasTrack ? qsTr("Now Playing, %1, %2").arg(Media.title).arg(Media.artist) : qsTr("Not Playing")

    function transport(action: string): void {
        if (!transportEnabled) {
            console.info("widgets: now playing transport suppressed in a development session");
            return;
        }
        if (action === "toggle")
            Media.togglePlaying();
        else if (action === "next")
            Media.next();
        else
            Media.previous();
    }

    Rectangle {
        id: art

        readonly property real edge: root.isSmall ? Tokens.widgetBigSize : root.height - 2 * root.padding

        x: root.padding
        y: root.padding
        width: edge
        height: edge
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        clip: true

        Image {
            anchors.fill: parent
            source: root.hasTrack ? ArtUrl.safe(Media.artUrl) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready
            sourceSize: Qt.size(art.width * 2, art.height * 2)
        }

        Icon {
            anchors.centerIn: parent
            size: parent.width / 2
            name: "media-play"
            color: Appearance.colors.textSecondary
            visible: !root.hasTrack
        }
    }

    Column {
        id: text

        x: root.isSmall ? root.padding : art.x + art.width + root.padding
        y: root.isSmall ? art.y + art.height + Tokens.spacingSm : root.padding
        width: root.width - x - root.padding
        spacing: Tokens.spacingXs

        WidgetLabel {
            width: parent.width
            text: root.hasTrack ? Media.title : qsTr("Not Playing")
            font.weight: Tokens.typographyMenuBoldWeight
            font.pixelSize: root.isSmall ? Tokens.typographyBodySize : Tokens.typographyTitleSize
            color: root.hasTrack ? Appearance.colors.text : Appearance.colors.textSecondary
            wrapMode: root.isSmall ? Text.Wrap : Text.NoWrap
            maximumLineCount: root.isSmall ? 2 : 1
        }

        WidgetLabel {
            width: parent.width
            visible: root.hasTrack && Media.artist !== ""
            text: Media.artist
            color: Appearance.colors.textSecondary
        }
    }

    Row {
        id: buttons

        visible: !root.isSmall
        x: text.x
        y: root.height - height - root.padding
        spacing: Tokens.spacingMd
        opacity: root.transportEnabled ? 1 : Tokens.materialDisabledOpacity

        Repeater {
            model: [
                {
                    icon: "media-prev",
                    name: qsTr("Previous track"),
                    action: "previous"
                },
                {
                    icon: Media.playing ? "media-pause" : "media-play",
                    name: Media.playing ? qsTr("Pause") : qsTr("Play"),
                    action: "toggle"
                },
                {
                    icon: "media-next",
                    name: qsTr("Next track"),
                    action: "next"
                }
            ]

            delegate: Item {
                id: button

                required property var modelData

                width: Tokens.panelWidgetTransportButton
                height: width
                activeFocusOnTab: root.transportEnabled
                Accessible.role: Accessible.Button
                Accessible.name: modelData.name
                Accessible.focusable: true
                Accessible.onPressAction: root.transport(modelData.action)

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                        root.transport(button.modelData.action);
                        event.accepted = true;
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                    border.width: button.activeFocus ? Tokens.controlFocusOutline : 0
                    border.color: Appearance.focusRingColor
                }

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.menuIconSize
                    name: button.modelData.icon
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.transportEnabled
                    cursorShape: Qt.ArrowCursor
                    onClicked: root.transport(button.modelData.action)
                }
            }
        }
    }
}
