pragma ComponentBehavior: Bound
import QtQuick
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
    // Live capture (the "full" profile, active desktop); otherwise one frame per window.
    property bool live: false

    readonly property real scaleFactor: screenW > 0 && screenH > 0 ? Math.min(width / screenW, height / screenH) : 0
    readonly property real offsetX: (width - screenW * scaleFactor) / 2
    readonly property real offsetY: (height - screenH * scaleFactor) / 2

    clip: true

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
                border.width: 1
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
                captureSource: card.modelData.toplevel ? card.modelData.toplevel : null
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
