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
    property color color: "#000000"
    // file: URL of the prepared picture ("" releases it).
    property string url: ""
    property size pictureSize: Qt.size(1, 1)

    // The artwork's palette (the window's base colour and the menu bar tone of the artwork come from it).
    readonly property var art: artwork.art
    // The picture is decoded and shown (never true for an empty or failed source).
    readonly property bool pictureReady: image.status === Image.Ready && root.url !== ""

    signal pictureLoaded
    signal pictureFailed

    anchors.fill: parent
    opacity: 0
    visible: opacity > 0

    WallpaperArt {
        id: artwork
        anchors.fill: parent
        visible: root.kind === "art"
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
}
