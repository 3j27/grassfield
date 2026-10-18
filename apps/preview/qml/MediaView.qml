pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import Grassfield.Ui

// Audio and video from a local file (the backend only passes file: URLs): play/pause and seeking.
FocusScope {
    id: root

    property var info: ({})
    property int fileIndex: 0
    // Start playing as soon as the media is loaded (Glance).
    property bool autoplay: false

    readonly property bool canZoom: false
    readonly property bool canRotate: false
    readonly property bool canSearch: false
    readonly property string zoomLabel: ""
    readonly property int pageCount: 1
    property int currentPage: 0
    readonly property bool isVideo: (root.info.kind ?? "") === "video"
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    property string failure: ""

    Accessible.role: Accessible.Window
    Accessible.name: root.isVideo ? qsTr("Video %1").arg(root.info.name ?? "") : qsTr("Audio %1").arg(root.info.name ?? "")

    function zoomIn(): void {
    }
    function zoomOut(): void {
    }
    function fit(): void {
    }
    function actualSize(): void {
    }
    function rotate(direction: int): void {
    }
    function goToPage(page: int): void {
    }
    function togglePlay(): void {
        if (root.playing)
            player.pause();
        else
            player.play();
    }

    function clock(ms: real): string {
        const total = Math.max(0, Math.round(ms / 1000));
        const s = total % 60;
        return Math.floor(total / 60) + ":" + (s < 10 ? "0" : "") + s;
    }

    MediaPlayer {
        id: player
        source: root.info.url ?? ""
        videoOutput: video
        audioOutput: AudioOutput {
        }
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia && root.autoplay)
            play()
        onErrorOccurred: (error, errorString) => root.failure = errorString
    }

    VideoOutput {
        id: video
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            bottom: bar.top
        }
        visible: root.isVideo && root.failure === ""
    }

    Message {
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            bottom: bar.top
        }
        visible: !video.visible
        title: root.failure === "" ? (root.info.name ?? "") : qsTr("This file cannot be played")
        text: root.failure === "" ? root.info.size ?? "" : root.failure
    }

    Item {
        id: bar
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: Tokens.previewControlsHeight

        Rectangle {
            width: parent.width
            height: 1
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        Item {
            id: playButton
            x: Tokens.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            width: Tokens.previewToolbarButtonSize
            height: Tokens.previewToolbarButtonSize
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.playing ? qsTr("Pause") : qsTr("Play")
            Accessible.focusable: true
            Accessible.onPressAction: root.togglePlay()

            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusControl
                color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
                visible: playMouse.containsMouse || playButton.activeFocus
            }
            Icon {
                anchors.centerIn: parent
                name: root.playing ? "media-pause" : "media-play"
                size: Tokens.menuIconSize
                color: Appearance.colors.text
            }
            MouseArea {
                id: playMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.togglePlay()
            }
        }

        Text {
            id: elapsed
            anchors {
                left: playButton.right
                leftMargin: Tokens.spacingSm
                verticalCenter: parent.verticalCenter
            }
            textFormat: Text.PlainText
            text: root.clock(player.position)
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        Text {
            id: total
            anchors {
                right: parent.right
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            textFormat: Text.PlainText
            text: root.clock(player.duration)
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        Slider {
            anchors {
                left: elapsed.right
                leftMargin: Tokens.spacingSm
                right: total.left
                rightMargin: Tokens.spacingSm
                verticalCenter: parent.verticalCenter
            }
            from: 0
            to: Math.max(1, player.duration)
            value: player.position
            accessibleName: qsTr("Position")
            onMoved: value => player.position = value
        }
    }
}
