import QtQuick
import Grassfield.Ui

// The view of one file: picks the viewer by kind (loaded on demand, so QtPdf and QtMultimedia are
// only loaded when needed) or shows why there is nothing to show.
Item {
    id: root

    required property var backend
    required property int fileIndex
    property bool autoplay: false
    property string searchText: ""

    readonly property var info: root.backend.inspect(root.fileIndex)
    // The loaded viewer (common interface: canZoom, zoomLabel, pageCount, currentPage, zoomIn() ...).
    readonly property var view: loader.item

    // The viewers scroll their content (PDF pages, zoomed images): nothing may be drawn over the toolbar.
    clip: true

    function fileSource(kind: string): string {
        switch (kind) {
        case "image":
            return "ImageView.qml";
        case "pdf":
            return "PdfView.qml";
        case "text":
            return "TextView.qml";
        case "audio":
        case "video":
            return "MediaView.qml";
        }
        return "";
    }

    // A new file gets a fresh viewer (zoom, rotation and page do not carry over).
    // The folder listing can move the opened file to another index: the same file keeps its viewer (no flash).
    property string shownUrl: ""
    Component.onCompleted: root.shownUrl = String(root.backend.files[root.fileIndex]?.url ?? "")
    onFileIndexChanged: {
        const url = String(root.backend.files[root.fileIndex]?.url ?? "");
        const same = url !== "" && url === root.shownUrl;
        root.shownUrl = url;
        if (same)
            return;
        loader.active = false;
        Qt.callLater(() => loader.active = Qt.binding(() => root.info.ok === true));
    }

    Loader {
        id: loader
        anchors.fill: parent
        active: root.info.ok === true
        source: root.fileSource(root.info.kind ?? "")
    }

    Binding {
        target: loader.item
        property: "info"
        value: root.info
        when: loader.item !== null
    }

    Binding {
        target: loader.item
        property: "fileIndex"
        value: root.fileIndex
        when: loader.item !== null
    }

    // Select Text in Images (ADR-0045 OC-2): the text and the QR codes of a still image (one frame, not animated), read
    // while preview.textInImages is on; the image view shows them.
    ImageText {
        id: imageText
        backend: root.backend
        fileIndex: root.fileIndex
        url: root.info.ok === true && root.info.kind === "image" && root.info.animated !== true && (root.info.frames ?? 1) === 1 ? String(root.info.url ?? "") : ""
        active: root.backend.textInImages === true
    }

    Binding {
        target: loader.item
        property: "backend"
        value: root.backend
        when: loader.item !== null && root.info.kind === "image"
    }

    Binding {
        target: loader.item
        property: "textPage"
        value: imageText.page
        when: loader.item !== null && root.info.kind === "image"
    }

    Binding {
        target: loader.item
        property: "codes"
        value: imageText.codes
        when: loader.item !== null && root.info.kind === "image"
    }

    Binding {
        target: loader.item
        property: "searchText"
        value: root.searchText
        when: loader.item !== null && root.info.kind === "pdf"
    }

    Binding {
        target: loader.item
        property: "autoplay"
        value: root.autoplay
        when: loader.item !== null && (root.info.kind === "audio" || root.info.kind === "video")
    }

    Message {
        anchors.fill: parent
        visible: root.info.ok !== true
        title: root.info.name ? DisplayName.text(root.info.name) : qsTr("Nothing to show")
        text: root.backend.files.length === 0 && root.backend.errors.length > 0 ? root.backend.errors.join("\n") : (root.info.error ?? "")
    }
}
