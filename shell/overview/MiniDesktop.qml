pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Window
import Quickshell.Wayland
import Grassfield.Ui
import qs.services

// A miniature of one desktop (docs/specs/overview.md, priority 12 of the visual audit 2026-10-25): the windows of the Space at
// their place, scaled to the thumbnail, each one a captured frame of the window (ScreencopyView, the capture API the
// thumbnail mode already uses) or, until a frame is there, a plain card with the app's icon. `windows` come from
// Compositor.spacesOn: {toplevel, appId, x, y, w, h} in the output's coordinates; the output is screenW x screenH.
Item {
    id: root

    property var windows: []
    property real screenW: 0
    property real screenH: 0
    // Windows drawn at most (the rest are hidden; the lowest ones first).
    property int maxWindows: Tokens.overviewMiniMaxWindows
    // Whether the windows are captured. The compositor plugin lays the windows of the ACTIVE desktop out while the Overview is
    // open, and a frame taken of one of those comes back as plain wallpaper (seen in the nested session, at any delay): the active
    // desktop shows the cards with the app icons, the other desktops show captured frames.
    property bool capture: true
    // Live capture of the frames; otherwise one frame per window.
    property bool live: false
    // The desktop's wallpaper under the windows (macOS draws each Desktop over its wallpaper; UI audit 2026-11-05 U29): what the
    // desktop shows on this output (WallpaperState.lockBackdrop: {kind: "picture"|"color"|"art", file, color, artwork,
    // variant}), or null for the plain plate. A picture is the helper's prepared still decoded once at the thumbnail's size and
    // shared by every Desktop of the output (one cache entry); the whole wallpaper is a static layer, masked to `radius`.
    property var wallpaper: null
    property real radius: 0

    readonly property real scaleFactor: screenW > 0 && screenH > 0 ? Math.min(width / screenW, height / screenH) : 0
    readonly property real offsetX: (width - screenW * scaleFactor) / 2
    readonly property real offsetY: (height - screenH * scaleFactor) / 2

    clip: true

    Rectangle {
        id: wallpaperMask
        anchors.fill: parent
        radius: root.radius
        visible: false
        layer.enabled: wallpaperArea.visible
    }

    Item {
        id: wallpaperArea

        readonly property string kind: root.wallpaper ? root.wallpaper.kind : ""

        anchors.fill: parent
        visible: kind !== "" && root.width > 0 && root.height > 0
        layer.enabled: visible
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: wallpaperMask
        }

        Image {
            anchors.fill: parent
            visible: wallpaperArea.kind === "picture"
            source: visible && root.wallpaper.file !== "" ? "file://" + root.wallpaper.file : ""
            sourceSize: Qt.size(Math.ceil(root.width * Screen.devicePixelRatio), Math.ceil(root.height * Screen.devicePixelRatio))
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }

        Rectangle {
            anchors.fill: parent
            visible: wallpaperArea.kind === "color"
            color: visible ? root.wallpaper.color : "transparent"
        }

        // Created only when the artwork is the wallpaper.
        Loader {
            anchors.fill: parent
            active: wallpaperArea.kind === "art"

            sourceComponent: GrassfieldArtwork {
                // lockBackdrop names a valid artwork and variant for every record (Artwork.js reads anything else as the default).
                artwork: root.wallpaper ? root.wallpaper.artwork : ""
                variant: root.wallpaper ? root.wallpaper.variant : ""
            }
        }
    }

    Repeater {
        model: root.windows.slice(-root.maxWindows)

        delegate: Item {
            id: card

            required property var modelData

            x: root.offsetX + modelData.x * root.scaleFactor
            y: root.offsetY + modelData.y * root.scaleFactor
            width: Math.max(1, modelData.w * root.scaleFactor)
            height: Math.max(1, modelData.h * root.scaleFactor)

            Rectangle {
                anchors.fill: parent
                radius: Tokens.overviewMiniWindowRadius
                color: Appearance.colors.materialTint
                border.width: Tokens.controlBorderWidth
                border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
            }

            TintedIcon {
                visible: !view.ready
                anchors.centerIn: parent
                size: Math.min(parent.width, parent.height) * Tokens.overviewMiniIconScale
                source: ThemeIcons.appIcon(Apps.lookup(card.modelData.appId) ? Apps.lookup(card.modelData.appId).icon : "", "application-x-executable")
                asynchronous: true
            }

            ScreencopyView {
                id: view
                anchors.fill: parent
                captureSource: root.capture && card.modelData.toplevel ? card.modelData.toplevel : null
                live: root.live
                paintCursor: false
                // A single frame can only be requested once the capture context knows the buffer size (sourceSize).
                readonly property bool ready: captureSource !== null && sourceSize.width > 0 && sourceSize.height > 0 && hasContent
                property bool snapshotTaken: false
                function snapshot(): void {
                    if (!live && captureSource !== null && sourceSize.width > 0 && sourceSize.height > 0 && !snapshotTaken) {
                        snapshotTaken = true;
                        captureFrame();
                    }
                }
                onSourceSizeChanged: snapshot()
                onLiveChanged: snapshot()
                onCaptureSourceChanged: snapshotTaken = false
            }
        }
    }
}
