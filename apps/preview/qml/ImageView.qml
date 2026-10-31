pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Image view: fit or zoomed, rotation by quarter turns (view only, the file is never written),
// pages of multi-page TIFF through the image provider, animation (GIF, WebP) through AnimatedImage.
Item {
    id: root

    property var info: ({})
    property int fileIndex: 0

    // Common view interface (see Content.qml).
    readonly property bool canZoom: true
    readonly property bool canRotate: true
    readonly property bool canSearch: false
    readonly property string zoomLabel: Math.round(root.viewScale * 100) + "%"
    readonly property int pageCount: root.info.animated ? 1 : (root.info.frames ?? 1)
    property int currentPage: 0
    property int turns: 0
    property bool fitMode: true
    property real zoom: 1

    readonly property bool swapped: root.turns % 2 !== 0
    readonly property real natW: root.info.width ?? 1
    readonly property real natH: root.info.height ?? 1
    readonly property real dispW: root.swapped ? root.natH : root.natW
    readonly property real dispH: root.swapped ? root.natW : root.natH
    readonly property real fitScale: Math.min(1, Math.min(flick.width / root.dispW, flick.height / root.dispH))
    readonly property real viewScale: root.fitMode ? root.fitScale : root.zoom

    Accessible.role: Accessible.Graphic
    Accessible.name: qsTr("Image %1").arg(root.info.name ?? "")
    // The double click of the TapHandler below (Zoom to Fit / Actual Size) as an accessible action (A11Y-09); the View menu
    // has the same two commands.
    Accessible.onPressAction: root.toggleActualSize()

    function toggleActualSize(): void {
        if (root.fitMode && root.fitScale < 1)
            root.actualSize();
        else
            root.fit();
    }

    function setZoom(value: real): void {
        const current = root.viewScale;
        root.fitMode = false;
        root.zoom = Math.max(Tokens.previewZoomMin, Math.min(Tokens.previewZoomMax, value));
        if (current !== root.zoom)
            flick.returnToBounds();
    }
    function zoomIn(): void {
        root.setZoom(root.viewScale * Tokens.previewZoomStep);
    }
    function zoomOut(): void {
        root.setZoom(root.viewScale / Tokens.previewZoomStep);
    }
    function fit(): void {
        root.fitMode = true;
    }
    function actualSize(): void {
        root.setZoom(1);
    }
    function rotate(direction: int): void {
        root.turns = ((root.turns + direction) % 4 + 4) % 4;
    }
    function goToPage(page: int): void {
        root.currentPage = Math.max(0, Math.min(root.pageCount - 1, page));
    }

    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: Math.max(width, holder.width)
        contentHeight: Math.max(height, holder.height)

        Item {
            id: holder
            width: root.dispW * root.viewScale
            height: root.dispH * root.viewScale
            x: Math.max(0, (flick.contentWidth - width) / 2)
            y: Math.max(0, (flick.contentHeight - height) / 2)

            Image {
                anchors.centerIn: parent
                width: root.natW * root.viewScale
                height: root.natH * root.viewScale
                rotation: root.turns * 90
                visible: !(root.info.animated ?? false)
                source: root.info.url && !root.info.animated ? "image://preview/" + root.currentPage + "/" + root.fileIndex : ""
                asynchronous: true
                retainWhileLoading: true
                cache: false
                mipmap: true
                smooth: true
                fillMode: Image.Stretch
            }

            AnimatedImage {
                anchors.centerIn: parent
                width: root.natW * root.viewScale
                height: root.natH * root.viewScale
                rotation: root.turns * 90
                visible: root.info.animated ?? false
                source: root.info.url && root.info.animated ? root.info.url : ""
                // Under Reduce Motion an animated image shows its first frame (ADR-0039 step 5).
                playing: visible && !Appearance.reduceMotion
                cache: false
                smooth: true
                fillMode: Image.Stretch
            }
        }

        WheelHandler {
            acceptedModifiers: Qt.ControlModifier
            onWheel: event => {
                if (event.angleDelta.y > 0)
                    root.zoomIn();
                else if (event.angleDelta.y < 0)
                    root.zoomOut();
            }
        }

        // Double click toggles between Zoom to Fit and Actual Size (macOS Preview).
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: root.toggleActualSize()
        }

        PinchHandler {
            target: null
            onScaleChanged: delta => root.setZoom(root.viewScale * delta)
        }
    }
}
