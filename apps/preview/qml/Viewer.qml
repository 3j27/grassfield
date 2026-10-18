pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grassfield Preview: toolbar (sidebar, zoom, rotate, pages, search), sidebar (file list when several
// files are open, page thumbnails for PDF) and the view of the current file. Nothing is ever written.
Window {
    id: win

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu

    property int current: 0
    property bool sidebarOpen: true
    property bool searchOpen: false
    readonly property int fileCount: win.backend.files.length
    readonly property var view: content.view
    readonly property bool isPdf: content.info.kind === "pdf" && content.info.ok === true
    readonly property bool hasSidebar: win.fileCount > 1 || win.isPdf
    readonly property bool showSidebar: win.sidebarOpen && win.hasSidebar
    readonly property int pages: win.view ? win.view.pageCount : 1

    title: content.info.name ? content.info.name.replace(/[\r\n]+/g, "\u23CE") : qsTr("Preview")
    width: Tokens.previewWindowWidth
    height: Tokens.previewWindowHeight
    minimumWidth: Tokens.previewWindowMinWidth
    minimumHeight: Tokens.previewWindowMinHeight
    visible: true
    color: Appearance.colors.materialTint

    Theme {
        backend: win.backend
    }

    function go(delta: int): void {
        if (win.fileCount > 1)
            win.current = (win.current + delta + win.fileCount) % win.fileCount;
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
        sequence: "Ctrl+Shift+S"
        onActivated: win.sidebarOpen = !win.sidebarOpen
        onActivatedAmbiguously: win.sidebarOpen = !win.sidebarOpen
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
    Shortcut {
        sequence: "PgUp"
        enabled: content.info.kind === "image" && win.pages > 1
        onActivated: win.view.goToPage(win.view.currentPage - 1)
    }
    Shortcut {
        sequence: "PgDown"
        enabled: content.info.kind === "image" && win.pages > 1
        onActivated: win.view.goToPage(win.view.currentPage + 1)
    }
    Shortcut {
        sequence: "Space"
        enabled: (content.info.kind === "audio" || content.info.kind === "video") && !searchInput.activeFocus
        onActivated: win.view.togglePlay()
    }
    Shortcut {
        sequence: "Esc"
        enabled: win.searchOpen
        onActivated: win.closeSearch()
    }

    // ---- toolbar ---------------------------------------------------------------------------------

    Item {
        id: toolbar
        width: parent.width
        height: Tokens.previewToolbarHeight

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
        }

        ToolButton {
            id: sidebarButton
            x: Tokens.spacingMd
            anchors.verticalCenter: parent.verticalCenter
            visible: win.hasSidebar
            text: qsTr("Sidebar")
            onClicked: win.sidebarOpen = !win.sidebarOpen
        }

        Row {
            id: tools
            anchors.centerIn: parent
            spacing: Tokens.spacingSm

            ToolButton {
                text: "−"
                label: qsTr("Zoom Out")
                enabled: win.view?.canZoom ?? false
                onClicked: win.view.zoomOut()
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.previewToolbarButtonSize * 1.5
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: win.view?.zoomLabel ?? ""
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Zoom %1").arg(text)
            }
            ToolButton {
                text: "+"
                label: qsTr("Zoom In")
                enabled: win.view?.canZoom ?? false
                onClicked: win.view.zoomIn()
            }
            ToolButton {
                text: qsTr("Fit")
                label: qsTr("Fit to Window")
                enabled: win.view?.canZoom ?? false
                onClicked: win.view.fit()
            }
            ToolButton {
                text: qsTr("Rotate")
                label: qsTr("Rotate Right")
                enabled: win.view?.canRotate ?? false
                onClicked: win.view.rotate(1)
            }
            ToolButton {
                visible: win.pages > 1
                text: "‹"
                label: qsTr("Previous Page")
                enabled: (win.view?.currentPage ?? 0) > 0
                onClicked: win.view.goToPage(win.view.currentPage - 1)
            }
            Text {
                visible: win.pages > 1
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: qsTr("%1 / %2").arg((win.view?.currentPage ?? 0) + 1).arg(win.pages)
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Page %1 of %2").arg((win.view?.currentPage ?? 0) + 1).arg(win.pages)
            }
            ToolButton {
                visible: win.pages > 1
                text: "›"
                label: qsTr("Next Page")
                enabled: (win.view?.currentPage ?? 0) < win.pages - 1
                onClicked: win.view.goToPage(win.view.currentPage + 1)
            }
        }

        // Search field (PDF).
        Rectangle {
            id: searchBox
            anchors {
                right: parent.right
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            visible: win.view?.canSearch ?? false
            width: Tokens.previewSearchWidth
            height: Tokens.previewToolbarButtonSize
            radius: Tokens.radiusControl
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            border.width: searchInput.activeFocus ? Tokens.controlFocusRing : 0
            border.color: Appearance.colors.accent

            Icon {
                id: searchIcon
                name: "search"
                size: Tokens.menuIconSize
                color: Appearance.colors.textSecondary
                x: Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
            }

            TextInput {
                id: searchInput
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
                    visible: searchInput.text === "" && !searchInput.activeFocus
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
                    rightMargin: Tokens.spacingSm
                    verticalCenter: parent.verticalCenter
                }
                visible: searchInput.text !== ""
                textFormat: Text.PlainText
                text: win.view && win.view.matches !== undefined ? qsTr("%1 found").arg(win.view.matches) : ""
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
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
        width: win.showSidebar ? Tokens.previewSidebarWidth : 0
        visible: win.showSidebar
        clip: true

        Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
        }

        // Files, when several were opened.
        ListView {
            id: fileList
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                margins: Tokens.spacingSm
            }
            height: win.fileCount > 1 ? (win.isPdf ? Math.min(contentHeight, parent.height / 3) : parent.height - 2 * Tokens.spacingSm) : 0
            visible: win.fileCount > 1
            clip: true
            model: win.backend.files
            currentIndex: win.current
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Files")

            delegate: Item {
                id: row

                required property int index
                required property var modelData

                width: fileList.width
                height: Tokens.previewSidebarItemHeight
                Accessible.role: Accessible.ListItem
                Accessible.name: row.modelData.name
                Accessible.selected: row.index === win.current

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.radiusControl
                    color: row.index === win.current ? Appearance.colors.accent : (rowMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
                }
                Text {
                    anchors {
                        fill: parent
                        leftMargin: Tokens.spacingSm
                        rightMargin: Tokens.spacingSm
                    }
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideMiddle
                    textFormat: Text.PlainText
                    maximumLineCount: 1
                    // A file name may contain line breaks: keep one line, shown as the return symbol.
                    text: row.modelData.name.replace(/[\r\n]+/g, "\u23CE")
                    color: row.index === win.current ? Appearance.colors.accentText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
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
