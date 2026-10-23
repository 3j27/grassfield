pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grassfield Preview: floating toolbar (sidebar, title and "n of N", previous/next, zoom, rotate, info, search), thumbnail
// sidebar (the files of the folder when several are open, page thumbnails for PDF) and the view of the current file.
// Nothing is ever written: zoom, rotation and page are properties of the view.
Window {
    id: win

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu

    property int current: win.backend.startIndex
    // Several files named on the command line show their list at once; the folder of a single image starts without it.
    property bool sidebarOpen: !win.backend.browsing
    property bool searchOpen: false
    property bool infoOpen: false
    property bool slideshow: false
    property bool slideshowPaused: false
    readonly property int fileCount: win.backend.files.length
    readonly property bool canGoPrevious: win.current > 0
    readonly property bool canGoNext: win.current < win.fileCount - 1
    readonly property var view: content.view
    readonly property bool isPdf: content.info.kind === "pdf" && content.info.ok === true
    readonly property bool hasSidebar: win.fileCount > 1 || win.isPdf
    readonly property bool showSidebar: win.sidebarOpen && win.hasSidebar
    readonly property int pages: win.view ? win.view.pageCount : 1
    readonly property bool onImage: content.info.kind === "image" && content.info.ok === true
    // Second line of the title: the position among the files, then the page of a document.
    readonly property string subtitle: {
        const parts = [];
        if (win.fileCount > 1)
            parts.push(qsTr("%1 of %2").arg(win.current + 1).arg(win.fileCount));
        if (win.pages > 1)
            parts.push(qsTr("Page %1 of %2").arg((win.view?.currentPage ?? 0) + 1).arg(win.pages));
        return parts.join("  ·  ");
    }

    title: content.info.name ? content.info.name.replace(/[\r\n]+/g, "⏎") : qsTr("Preview")
    width: Tokens.previewWindowWidth
    height: Tokens.previewWindowHeight
    minimumWidth: Tokens.previewWindowMinWidth
    minimumHeight: Tokens.previewWindowMinHeight
    visible: true
    color: Appearance.colors.materialTint

    Theme {
        backend: win.backend
    }

    // Previous or next file of the list (no wrap, like a file manager); a slideshow keeps its own timer.
    function go(delta: int): void {
        const next = Math.max(0, Math.min(win.fileCount - 1, win.current + delta));
        if (next !== win.current)
            win.current = next;
    }

    function openSearch(): void {
        win.searchOpen = true;
        searchInput.forceActiveFocus();
        searchInput.selectAll();
    }

    function closeSearch(): void {
        win.searchOpen = false;
        searchInput.text = "";
        content.forceActiveFocus();
        if (win.view)
            win.view.forceActiveFocus();
    }

    function toggleSlideshow(): void {
        if (win.slideshow) {
            win.endSlideshow();
            return;
        }
        if (win.fileCount < 2)
            return;
        win.slideshowPaused = false;
        win.slideshow = true;
        win.visibility = Window.FullScreen;
    }

    function endSlideshow(): void {
        win.slideshow = false;
        win.visibility = Window.Windowed;
    }

    onCurrentChanged: {
        if (win.searchOpen)
            win.closeSearch();
    }

    // Global menu (T1). Its shortcuts repeat some of the ones below: every Shortcut whose key is also a menu shortcut
    // acts on activatedAmbiguously too (Qt hands such a key to one of the two per press, see GlobalMenu.qml).
    Loader {
        active: win.globalMenu
        sourceComponent: GlobalMenu {
            win: win
        }
    }

    // A slideshow shows each file for a while, then stops after the last one.
    Timer {
        interval: Tokens.previewSlideshowInterval
        repeat: true
        running: win.slideshow && !win.slideshowPaused
        onTriggered: {
            if (win.canGoNext)
                win.go(1);
            else
                win.endSlideshow();
        }
    }

    // Keys: plain keys are ignored while the search field has the focus.
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: win.close()
        onActivatedAmbiguously: win.close()
    }
    Shortcut {
        sequence: "Ctrl+Q"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+F"
        enabled: win.view?.canSearch ?? false
        onActivated: win.openSearch()
        onActivatedAmbiguously: win.openSearch()
    }
    Shortcut {
        sequence: "Ctrl+G"
        enabled: (win.view?.canSearch ?? false) && win.searchOpen
        onActivated: win.view.nextMatch()
        onActivatedAmbiguously: win.view.nextMatch()
    }
    Shortcut {
        sequence: "Ctrl+Shift+G"
        enabled: (win.view?.canSearch ?? false) && win.searchOpen
        onActivated: win.view.previousMatch()
        onActivatedAmbiguously: win.view.previousMatch()
    }
    Shortcut {
        sequences: ["Ctrl+Alt+2", "Ctrl+Shift+S"]
        enabled: win.hasSidebar
        onActivated: win.sidebarOpen = !win.sidebarOpen
        onActivatedAmbiguously: win.sidebarOpen = !win.sidebarOpen
    }
    Shortcut {
        sequence: "Ctrl+I"
        onActivated: win.infoOpen = !win.infoOpen
        onActivatedAmbiguously: win.infoOpen = !win.infoOpen
    }
    Shortcut {
        sequence: "Ctrl+Shift+F"
        enabled: win.fileCount > 1
        onActivated: win.toggleSlideshow()
        onActivatedAmbiguously: win.toggleSlideshow()
    }
    Shortcut {
        sequence: "Ctrl+R"
        enabled: win.view?.canRotate ?? false
        onActivated: win.view.rotate(1)
        onActivatedAmbiguously: win.view.rotate(1)
    }
    Shortcut {
        sequence: "Ctrl+L"
        enabled: win.view?.canRotate ?? false
        onActivated: win.view.rotate(-1)
        onActivatedAmbiguously: win.view.rotate(-1)
    }
    Shortcut {
        sequences: ["+", "=", "Ctrl++", "Ctrl+="]
        enabled: (win.view?.canZoom ?? false) && !searchInput.activeFocus
        onActivated: win.view.zoomIn()
        onActivatedAmbiguously: win.view.zoomIn()
    }
    Shortcut {
        sequences: ["-", "Ctrl+-"]
        enabled: (win.view?.canZoom ?? false) && !searchInput.activeFocus
        onActivated: win.view.zoomOut()
        onActivatedAmbiguously: win.view.zoomOut()
    }
    Shortcut {
        sequences: ["0", "Ctrl+0"]
        enabled: (win.view?.canZoom ?? false) && !searchInput.activeFocus
        onActivated: win.view.actualSize()
        onActivatedAmbiguously: win.view.actualSize()
    }
    Shortcut {
        sequence: "Ctrl+9"
        enabled: win.view?.canZoom ?? false
        onActivated: win.view.fit()
        onActivatedAmbiguously: win.view.fit()
    }
    Shortcut {
        sequence: "Left"
        enabled: win.fileCount > 1 && !searchInput.activeFocus
        onActivated: win.go(-1)
        onActivatedAmbiguously: win.go(-1)
    }
    Shortcut {
        sequence: "Right"
        enabled: win.fileCount > 1 && !searchInput.activeFocus
        onActivated: win.go(1)
        onActivatedAmbiguously: win.go(1)
    }
    // Page Up and Down turn the pages of a multi-page image; on any other image they go to the previous and next file.
    Shortcut {
        sequence: "PgUp"
        enabled: win.onImage && !searchInput.activeFocus && (win.pages > 1 || win.fileCount > 1)
        onActivated: win.pages > 1 ? win.view.goToPage(win.view.currentPage - 1) : win.go(-1)
    }
    Shortcut {
        sequence: "PgDown"
        enabled: win.onImage && !searchInput.activeFocus && (win.pages > 1 || win.fileCount > 1)
        onActivated: win.pages > 1 ? win.view.goToPage(win.view.currentPage + 1) : win.go(1)
    }
    Shortcut {
        sequence: "Space"
        enabled: (content.info.kind === "audio" || content.info.kind === "video" || win.slideshow) && !searchInput.activeFocus
        onActivated: win.slideshow ? win.slideshowPaused = !win.slideshowPaused : win.view.togglePlay()
    }
    Shortcut {
        sequence: "Esc"
        enabled: win.searchOpen || win.infoOpen || win.slideshow
        onActivated: {
            if (win.slideshow)
                win.endSlideshow();
            else if (win.infoOpen)
                win.infoOpen = false;
            else
                win.closeSearch();
        }
    }

    // ---- toolbar ---------------------------------------------------------------------------------

    Item {
        id: toolbar
        width: parent.width
        height: win.slideshow ? 0 : Tokens.previewToolbarHeight
        visible: !win.slideshow
        z: 2

        ToolbarGroup {
            id: sidebarGroup
            x: Tokens.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            visible: win.hasSidebar

            ToolButton {
                capsule: true
                accessibleName: qsTr("Thumbnails")
                checkable: true
                checked: win.showSidebar
                onClicked: win.sidebarOpen = !win.sidebarOpen

                Glyph {
                    anchors.centerIn: parent
                    kind: "sidebar"
                }
            }
        }

        // Title and subtitle ("3 of 12", "Page 2 of 8"): the same place as the macOS toolbar.
        Column {
            id: titleBlock
            anchors {
                left: sidebarGroup.visible ? sidebarGroup.right : parent.left
                leftMargin: Tokens.spacingMd
                right: tools.left
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            visible: width > 0

            Text {
                width: parent.width
                elide: Text.ElideMiddle
                textFormat: Text.PlainText
                text: win.title
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyMenuSize
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
            Text {
                width: parent.width
                visible: text !== ""
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: win.subtitle
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }

        Row {
            id: tools
            objectName: "toolsRow"
            anchors {
                right: parent.right
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            spacing: Tokens.spacingMd

            ToolbarGroup {
                visible: win.fileCount > 1

                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Previous")
                    enabled: win.canGoPrevious
                    onClicked: win.go(-1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "chevronLeft"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Next")
                    enabled: win.canGoNext
                    onClicked: win.go(1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "chevronRight"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Slideshow")
                    onClicked: win.toggleSlideshow()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "play"
                    }
                }
            }

            ToolbarGroup {
                visible: win.view?.canZoom ?? false

                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom Out")
                    onClicked: win.view.zoomOut()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "zoomOut"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom to Fit")
                    onClicked: win.view.fit()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "fit"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Zoom In")
                    onClicked: win.view.zoomIn()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "zoomIn"
                    }
                }
            }

            ToolbarGroup {
                visible: win.view?.canRotate ?? false

                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Rotate Left")
                    onClicked: win.view.rotate(-1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "rotateLeft"
                    }
                }
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Rotate Right")
                    onClicked: win.view.rotate(1)

                    Glyph {
                        anchors.centerIn: parent
                        kind: "rotateRight"
                    }
                }
            }

            ToolbarGroup {
                ToolButton {
                    capsule: true
                    accessibleName: qsTr("Info")
                    checkable: true
                    checked: win.infoOpen
                    onClicked: win.infoOpen = !win.infoOpen

                    Glyph {
                        anchors.centerIn: parent
                        kind: "info"
                    }
                }
            }

            // Search (PDF): a circle that opens into a field.
            Item {
                id: searchBox
                visible: win.view?.canSearch ?? false
                width: win.searchOpen ? Tokens.previewSearchWidth : Tokens.previewToolbarCapsuleHeight
                height: Tokens.previewToolbarCapsuleHeight

                Material {
                    anchors.fill: parent
                    radius: height / 2
                }

                ToolButton {
                    anchors.centerIn: parent
                    visible: !win.searchOpen
                    capsule: true
                    accessibleName: qsTr("Search in document")
                    onClicked: win.openSearch()

                    Glyph {
                        anchors.centerIn: parent
                        kind: "search"
                    }
                }

                Glyph {
                    id: searchIcon
                    visible: win.searchOpen
                    kind: "search"
                    color: Appearance.colors.textSecondary
                    x: Tokens.spacingMd
                    anchors.verticalCenter: parent.verticalCenter
                }

                TextInput {
                    id: searchInput
                    TextCursor {}
                    visible: win.searchOpen
                    anchors {
                        left: searchIcon.right
                        leftMargin: Tokens.spacingSm
                        right: matches.left
                        rightMargin: Tokens.spacingSm
                        verticalCenter: parent.verticalCenter
                    }
                    clip: true
                    color: Appearance.colors.text
                    selectionColor: Appearance.colors.accent
                    selectedTextColor: Appearance.colors.accentText
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    Accessible.role: Accessible.EditableText
                    Accessible.name: qsTr("Search in document")
                    Keys.onPressed: event => {
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && win.view) {
                            if (event.modifiers & Qt.ShiftModifier)
                                win.view.previousMatch();
                            else
                                win.view.nextMatch();
                            event.accepted = true;
                        }
                    }
                    Keys.onEscapePressed: win.closeSearch()

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: searchInput.text === ""
                        textFormat: Text.PlainText
                        text: qsTr("Search")
                        color: Appearance.colors.textSecondary
                        font: searchInput.font
                    }
                }

                Text {
                    id: matches
                    anchors {
                        right: parent.right
                        rightMargin: Tokens.spacingMd
                        verticalCenter: parent.verticalCenter
                    }
                    visible: win.searchOpen && searchInput.text !== ""
                    textFormat: Text.PlainText
                    text: win.view && win.view.matches !== undefined ? qsTr("%1 found").arg(win.view.matches) : ""
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }
            }
        }
    }

    // ---- info -------------------------------------------------------------------------------------

    Item {
        id: info
        z: 3
        visible: win.infoOpen && !win.slideshow
        x: win.width - width - Tokens.spacingMd
        y: toolbar.height
        width: Tokens.previewInfoWidth
        height: infoRows.height + 2 * Tokens.spacingMd
        Accessible.role: Accessible.Pane
        Accessible.name: qsTr("Info")

        Material {
            anchors.fill: parent
            radius: Tokens.radiusMenu
        }

        Column {
            id: infoRows
            x: Tokens.spacingMd
            y: Tokens.spacingMd
            width: parent.width - 2 * Tokens.spacingMd

            Repeater {
                model: {
                    const i = content.info;
                    const rows = [[qsTr("Name"), i.name ?? ""], [qsTr("Kind"), i.type ?? ""]];
                    if (i.width !== undefined && i.height !== undefined)
                        rows.push([qsTr("Dimensions"), qsTr("%1 × %2 pixels").arg(i.width).arg(i.height)]);
                    rows.push([qsTr("Size"), i.size ?? ""], [qsTr("Modified"), i.modified ?? ""], [qsTr("Where"), i.folder ?? ""]);
                    return rows;
                }

                Item {
                    id: infoRow

                    required property var modelData

                    width: infoRows.width
                    height: Tokens.previewInfoRowHeight
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("%1: %2").arg(infoRow.modelData[0]).arg(infoRow.modelData[1])

                    Text {
                        id: infoLabel
                        width: Tokens.previewInfoWidth / 3
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: infoRow.modelData[0]
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                    Text {
                        anchors {
                            left: infoLabel.right
                            leftMargin: Tokens.spacingSm
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                        }
                        elide: Text.ElideMiddle
                        textFormat: Text.PlainText
                        text: infoRow.modelData[1].replace(/[\r\n]+/g, "⏎")
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }
        }
    }

    // ---- sidebar -----------------------------------------------------------------------------------

    Item {
        id: sidebar
        anchors {
            top: toolbar.bottom
            bottom: parent.bottom
            left: parent.left
        }
        width: win.showSidebar && !win.slideshow ? Tokens.previewSidebarWidth + Tokens.spacingSm : 0
        visible: width > 0
        clip: true

        // A floating panel inset from the window edges (macOS 26).
        Rectangle {
            id: panel
            anchors {
                fill: parent
                leftMargin: Tokens.spacingSm
                bottomMargin: Tokens.spacingSm
            }
            radius: Tokens.radiusPanel
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            border.width: 1
            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
            clip: true

            // Files: thumbnails of the images, names of the other kinds. Beside the page thumbnails of a PDF they are
            // a short list of names.
            ListView {
                id: fileList

                readonly property bool compact: win.isPdf

                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    margins: Tokens.spacingSm
                }
                height: win.fileCount > 1 ? (fileList.compact ? Math.min(contentHeight, panel.height / 3) : panel.height - 2 * Tokens.spacingSm) : 0
                visible: win.fileCount > 1
                clip: true
                spacing: Tokens.spacingXs
                model: win.backend.files
                currentIndex: win.current
                highlightMoveDuration: 0
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Files")

                onCurrentIndexChanged: fileList.positionViewAtIndex(fileList.currentIndex, ListView.Contain)
                Component.onCompleted: fileList.positionViewAtIndex(fileList.currentIndex, ListView.Center)

                delegate: Item {
                    id: row

                    required property int index
                    required property var modelData
                    readonly property bool selected: row.index === win.current
                    readonly property real cellHeight: Math.round(Tokens.previewThumbnailWidth * 3 / 4)

                    width: fileList.width
                    height: fileList.compact ? Tokens.previewSidebarItemHeight : row.cellHeight + labelText.implicitHeight + 3 * Tokens.spacingSm
                    Accessible.role: Accessible.ListItem
                    Accessible.name: row.modelData.name
                    Accessible.selected: row.selected

                    // Selection: a rounded accent plate around thumbnail and name (compact: the row).
                    Rectangle {
                        anchors.fill: parent
                        radius: fileList.compact ? Tokens.radiusControl : Tokens.radiusMenu
                        color: row.selected ? Appearance.colors.accent : (rowMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
                    }

                    Item {
                        id: thumb
                        visible: !fileList.compact
                        x: (parent.width - width) / 2
                        y: Tokens.spacingSm
                        width: Tokens.previewThumbnailWidth
                        height: row.cellHeight

                        Image {
                            anchors.fill: parent
                            visible: row.modelData.kind === "image"
                            // Decoded at its size by the provider (image://preview/thumb), twice for a sharp edge.
                            source: row.modelData.kind === "image" && !fileList.compact ? "image://preview/thumb/" + row.index : ""
                            sourceSize: Qt.size(width * 2, height * 2)
                            asynchronous: true
                            cache: true
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            mipmap: true
                        }
                        Rectangle {
                            anchors.fill: parent
                            visible: row.modelData.kind !== "image"
                            radius: Tokens.radiusControl
                            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        }
                    }

                    Text {
                        id: labelText
                        anchors {
                            left: parent.left
                            right: parent.right
                            leftMargin: Tokens.spacingSm
                            rightMargin: Tokens.spacingSm
                            top: fileList.compact ? undefined : thumb.bottom
                            topMargin: Tokens.spacingXs
                            verticalCenter: fileList.compact ? parent.verticalCenter : undefined
                        }
                        horizontalAlignment: fileList.compact ? Text.AlignLeft : Text.AlignHCenter
                        elide: Text.ElideMiddle
                        textFormat: Text.PlainText
                        maximumLineCount: 1
                        // A file name may contain line breaks: keep one line, shown as the return symbol.
                        text: row.modelData.name.replace(/[\r\n]+/g, "⏎")
                        color: row.selected ? Appearance.colors.accentText : Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: fileList.compact ? Tokens.typographyMenuSize : Tokens.typographyCaptionSize
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: win.current = row.index
                    }
                }
            }

            Loader {
                id: thumbs
                anchors {
                    top: fileList.bottom
                    topMargin: Tokens.spacingSm
                    bottom: parent.bottom
                    left: parent.left
                    right: parent.right
                    margins: Tokens.spacingSm
                }
                active: win.isPdf && win.view !== null
                source: "Thumbnails.qml"
            }

            Binding {
                target: thumbs.item
                property: "document"
                value: win.view?.document
                when: thumbs.item !== null && win.view !== null
            }
            Binding {
                target: thumbs.item
                property: "pdfView"
                value: win.view
                when: thumbs.item !== null && win.view !== null
            }
        }
    }

    Content {
        id: content
        anchors {
            top: toolbar.bottom
            bottom: parent.bottom
            left: sidebar.right
            right: parent.right
        }
        backend: win.backend
        fileIndex: win.current
        searchText: searchInput.text
        focus: true
    }
}
