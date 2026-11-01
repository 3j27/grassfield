pragma ComponentBehavior: Bound
import QtQuick

// One slot of the desktop wallpaper (ADR-0016, Wallpaper.qml): the content of a slot is ONE of the three kinds of wallpaper,
// the Grassfield artwork, a solid colour, or a prepared picture. Every kind goes through the same two-slot model of
// Wallpaper.qml (incoming on top, visible only when ready, crossfaded over the outgoing one, a failure keeps what is on
// screen), so that nothing but the outgoing slot, the incoming slot or a blend of the two can ever show. A slot is
// transparent (opacity 0) while it is not on screen, and nothing in it sets its own opacity.
Item {
    id: root

    // "art" | "color" | "picture"
    property string kind: "art"
    // The artwork and its variant (ADR-0040 step 2; GrassfieldArtwork.qml): set with the kind "art".
    property string artwork: "grassfield"
    property string variant: "evening.dark"
    // The moving variant of the Grassfield artwork (wallpaper.moving, ADR-0040 step 9, as the integrator decided in the review
    // of e067f26f): the desktop draws its clouds still, where the last lock left them (`motionMs`, WallpaperState.motionOf);
    // only the lock screen moves them. Nothing here runs a Timer for it.
    property bool moving: false
    property real motionMs: 0
    property color color: "#000000"
    // file: URL of the prepared picture ("" releases it).
    property string url: ""
    property size pictureSize: Qt.size(1, 1)
    // A video wallpaper (ADR-0016 W7): the picture above is its poster; `video` is the file: URL of the transcoded H.264 file
    // played over it, but only while the slot is on screen (`onScreen`, so that an incoming slot that still fades in, and a
    // slot being released, never start a decoder) and as the pause policy `playPolicy` allows.
    property string video: ""
    property string videoFit: "fill"
    property int posterMs: 0
    property string videoPath: ""
    // The output the crash marker of this slot's video belongs to.
    property string markerOwner: ""
    property bool onScreen: false
    property string playPolicy: "pause"
    signal videoFailed(string message)

    // The artwork's palette (the window's base colour and the menu bar tone of the artwork come from it).
    readonly property var art: artworkItem.art
    readonly property var artPalette: artworkItem.artPalette
    // The picture is decoded and shown (never true for an empty or failed source).
    readonly property bool pictureReady: image.status === Image.Ready && root.url !== ""

    signal pictureLoaded
    signal pictureFailed

    anchors.fill: parent
    opacity: 0
    visible: opacity > 0

    WallpaperArt {
        id: artworkItem
        anchors.fill: parent
        visible: root.kind === "art"
        artwork: root.artwork
        variant: root.variant
        moving: root.moving
        motionMs: root.motionMs
    }

    Rectangle {
        anchors.fill: parent
        visible: root.kind === "color"
        color: root.color
    }

    Image {
        id: image
        anchors.fill: parent
        visible: root.kind === "picture"
        source: root.kind === "picture" ? root.url : ""
        asynchronous: true
        cache: false
        smooth: false
        fillMode: Image.Stretch
        // An output mode or scale change reloads the picture: the old texture stays on screen until the new one decoded.
        retainWhileLoading: true
        sourceSize: root.pictureSize
        onStatusChanged: {
            if (status === Image.Ready && root.url !== "")
                root.pictureLoaded();
            else if (status === Image.Error)
                root.pictureFailed();
        }
    }

    // Loaded only for a video wallpaper that is on screen: no QtMultimedia object exists otherwise.
    // The video is playing (a frame is being decoded), for the dev status and the tests.
    readonly property bool videoPlaying: (videoLoader.item as WallpaperVideo)?.playing === true
    // The player has shown a frame (it is playing or paused on its last frame).
    readonly property bool videoShown: (videoLoader.item as WallpaperVideo)?.hasFrame === true

    Loader {
        id: videoLoader
        anchors.fill: parent
        active: root.kind === "picture" && root.video !== "" && root.onScreen
        sourceComponent: WallpaperVideo {
            source: root.video
            fit: root.videoFit
            posterMs: root.posterMs
            policy: root.playPolicy
            markerPath: root.videoPath
            markerOwner: root.markerOwner
            onFailed: message => root.videoFailed(message)
        }
    }
}
