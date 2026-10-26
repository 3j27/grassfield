pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// The preview pane at the right of a view (macOS 27 Finder, View > Show Preview, Shift+Cmd+P; docs/specs/files.md
// "Preview pane"): the selected item's preview (large in the icon and list views, a small one beside the name in the
// gallery, whose own preview is the view), its name, kind and size, an Information section (Show More adds the rest),
// its tags, and the quick actions of the selection at the bottom (Rotate Left for pictures; More… adds Rotate Right).
// With nothing selected it shows the folder; with several items, how many.
Item {
    id: root

    required property var tab
    // The listing whose selection is shown (the tab's active folder).
    required property var model
    // The large preview at the top (icon and list views); the gallery shows a small one beside the name.
    property bool large: true
    // The pane's own fill (the column view's preview column sits on the window's white instead).
    property bool filled: true
    // How far the fill reaches up behind the toolbar (macOS 27: the pane runs to the top of the window, the toolbar's
    // items over it); 0 with the tab bar or a banner shown.
    property real topExtension: 0
    property bool showMore: false
    // Bumped by every change of the listing (dates, names, tags, thumbnails) so the pane reads the item again.
    property int revision: 0
    readonly property int selectedCount: root.model ? root.model.selectedCount : 0
    readonly property int row: {
        root.revision;
        const m = root.model;
        if (!m || m.selectedCount !== 1)
            return -1;
        if (m.currentRow >= 0 && m.isSelected(m.currentRow))
            return m.currentRow;
        const rows = m.selectedRows();
        return rows.length > 0 ? rows[0] : -1;
    }
    readonly property var info: {
        root.revision;
        const m = root.model;
        if (!m || root.selectedCount > 1)
            return null;
        return m.info(root.row);
    }
    // The selection's quick actions (FilesApp.rotatableImages): local pictures Files can rotate.
    readonly property var rotatable: {
        root.revision;
        const m = root.model;
        return m && root.selectedCount > 0 ? root.tab.app.rotatableImages(m.selectedUrls()) : [];
    }
    readonly property bool hasActions: root.rotatable.length > 0 && root.rotatable.length === root.selectedCount
    // What the Tags field tags: the selection, else the shown folder.
    readonly property var tagUrls: {
        root.revision;
        const m = root.model;
        if (!m)
            return [];
        if (root.selectedCount > 0)
            return m.selectedUrls();
        return root.info && root.info.url ? [root.info.url] : [];
    }
    readonly property bool taggable: root.tagUrls.length > 0 && root.tab.app.tagsUnavailable(root.tagUrls) === ""

    width: Tokens.filesPreviewPaneWidth
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Preview")

    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onDataChanged(): void {
            root.revision++;
        }
        function onSelectionChanged(): void {
            root.revision++;
        }
        function onCurrentRowChanged(): void {
            root.revision++;
        }
    }

    // The large thumbnail of the shown item is asked for while it is shown (the gallery's own pipeline). Not in the
    // gallery, whose own pages ask for it (a cancel here would drop their request).
    property url requested
    onRowChanged: {
        const m = root.model;
        if (!m || !root.large)
            return;
        if (String(root.requested) !== "")
            m.cancelPreview(root.requested, true);
        root.requested = root.row >= 0 ? m.urlAt(root.row) : "";
        if (root.row >= 0)
            m.requestPreview(root.row, true);
    }
    Component.onDestruction: {
        if (root.model && String(root.requested) !== "")
            root.model.cancelPreview(root.requested, true);
    }

    Rectangle {
        y: -root.topExtension
        width: parent.width
        height: parent.height + root.topExtension
        visible: root.filled
        color: Appearance.colors.sidebarFill
    }

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.bottomMargin: root.hasActions ? actions.height : 0
        acceptedButtons: Qt.NoButton
        contentHeight: details.implicitHeight + Tokens.filesPreviewTop + Tokens.spacingLg
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: details
            x: Tokens.filesPreviewInset
            y: Tokens.filesPreviewTop
            width: parent.width - 2 * Tokens.filesPreviewInset
            visible: root.info !== null || root.selectedCount > 1

            // Large preview (icon and list views): the gallery-size thumbnail, never enlarged past its pixels, else
            // the icon-size one, else the type icon.
            Item {
                id: bigBox
                visible: root.large
                width: parent.width
                height: root.large ? Math.min(width, Math.max(0, root.height * Tokens.filesPreviewLargeShare)) + Tokens.filesPreviewSectionGap : 0

                Item {
                    width: parent.width
                    height: parent.height - Tokens.filesPreviewSectionGap

                    Image {
                        id: bigImage
                        anchors.centerIn: parent
                        width: Math.min(parent.width, implicitWidth)
                        height: Math.min(parent.height, implicitHeight)
                        source: root.info && root.info.largeThumbnail ? root.info.largeThumbnail : root.info && root.info.thumbnail ? root.info.thumbnail : ""
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        visible: status === Image.Ready
                    }

                    FileIcon {
                        anchors.centerIn: parent
                        visible: !bigImage.visible
                        size: Math.min(parent.width, parent.height, Tokens.filesGalleryIconSize)
                        iconName: root.selectedCount > 1 ? "folder-documents" : root.info && root.info.iconName ? root.info.iconName : ""
                        isDir: root.info !== null && root.info.isDir === true
                        folderColor: root.info && root.info.folderColor ? root.info.folderColor : ""
                        folderGlyph: root.info && root.info.folderGlyph ? root.info.folderGlyph : ""
                    }
                }
            }

            // Name block: a small preview beside it in the gallery.
            Item {
                width: parent.width
                height: Math.max(nameColumn.implicitHeight, root.large ? 0 : smallBox.height)

                // The small preview, centred on the name block (a two-line name in the capture): the picture fitted in
                // 42, rounded, on a soft shadow (macOS 27); the type icon until a thumbnail exists. The box is as high as
                // what it shows, so a one-line name is not pushed down by an empty square.
                Item {
                    id: smallBox
                    visible: !root.large
                    y: (parent.height - height) / 2
                    width: root.large ? 0 : Tokens.filesPreviewThumbBox
                    height: smallFrame.visible ? smallFrame.height : Tokens.filesPreviewThumb

                    Item {
                        id: smallFrame
                        anchors.centerIn: parent
                        readonly property real scale: smallImage.implicitWidth > 0 && smallImage.implicitHeight > 0 ? Math.min(1, Tokens.filesPreviewThumb / Math.max(smallImage.implicitWidth, smallImage.implicitHeight)) : 0
                        width: smallImage.implicitWidth * scale
                        height: smallImage.implicitHeight * scale
                        visible: smallImage.status === Image.Ready && scale > 0

                        RectangularShadow {
                            anchors.fill: parent
                            radius: Tokens.filesPreviewThumbRadius
                            blur: Tokens.filesPreviewThumbShadowBlur
                            offset: Qt.vector2d(0, Tokens.filesPreviewThumbShadowY)
                            color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.filesPreviewThumbShadowOpacity)
                        }

                        Rectangle {
                            id: smallMask
                            anchors.fill: parent
                            radius: Tokens.filesPreviewThumbRadius
                            visible: false
                            layer.enabled: smallFrame.visible
                        }

                        Image {
                            id: smallImage
                            anchors.fill: parent
                            source: root.info && root.info.thumbnail ? root.info.thumbnail : ""
                            sourceSize.width: Tokens.filesPreviewThumb * Tokens.filesThumbnailOversample
                            sourceSize.height: Tokens.filesPreviewThumb * Tokens.filesThumbnailOversample
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            layer.enabled: smallFrame.visible
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: smallMask
                            }
                        }
                    }

                    FileIcon {
                        anchors.centerIn: parent
                        visible: !smallFrame.visible
                        size: Tokens.filesPreviewThumb
                        iconName: root.selectedCount > 1 ? "folder-documents" : root.info && root.info.iconName ? root.info.iconName : ""
                        isDir: root.info !== null && root.info.isDir === true
                        folderColor: root.info && root.info.folderColor ? root.info.folderColor : ""
                        folderGlyph: root.info && root.info.folderGlyph ? root.info.folderGlyph : ""
                    }
                }

                Column {
                    id: nameColumn
                    x: root.large ? 0 : Tokens.filesPreviewThumbBox + Tokens.filesPreviewThumbGap
                    width: parent.width - x
                    spacing: Tokens.filesPreviewNameGap

                    Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: root.selectedCount > 1 ? qsTr("%1 items").arg(root.selectedCount) : root.info ? DisplayName.text(root.info.name) : ""
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        maximumLineCount: Tokens.filesPreviewNameLines
                        elide: Text.ElideRight
                        lineHeightMode: Text.FixedHeight
                        lineHeight: Tokens.filesPreviewNameLineHeight
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyTitleSize
                        font.weight: Tokens.typographyMenuBoldWeight
                        Accessible.role: Accessible.Heading
                        Accessible.name: text
                    }

                    Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        visible: text !== ""
                        text: !root.info ? "" : root.info.isDir || root.info.size < 0 ? root.info.kind : qsTr("%1 – %2").arg(root.info.kind).arg(root.info.sizeText)
                        wrapMode: Text.Wrap
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }
                }
            }

            Item {
                width: 1
                height: Tokens.filesPreviewSectionGap
            }

            // Information, with Show More / Show Less.
            Item {
                width: parent.width
                height: Tokens.filesPreviewRowHeight
                visible: root.info !== null

                Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Information")
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    font.weight: Tokens.typographyMenuBoldWeight
                    Accessible.role: Accessible.Heading
                    Accessible.name: text
                }

                Text {
                    id: more
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.showMore ? qsTr("Show Less") : qsTr("Show More")
                    color: Appearance.colors.accent
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    Accessible.role: Accessible.Button
                    Accessible.name: text
                    Accessible.onPressAction: root.showMore = !root.showMore

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Tokens.spacingXs
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showMore = !root.showMore
                    }
                }
            }

            Repeater {
                model: !root.info ? [] : [
                    {label: qsTr("Created"), value: root.info.created, more: false},
                    {label: qsTr("Modified"), value: root.info.modified, more: false},
                    {label: qsTr("Dimensions"), value: root.info.dimensions ? root.info.dimensions : "", more: false},
                    {label: qsTr("Last opened"), value: root.info.accessed, more: true},
                    {label: qsTr("Size"), value: root.info.isDir ? "" : qsTr("%1 bytes").arg(root.info.bytes), more: true},
                    {label: qsTr("Where"), value: root.info.where, more: true}
                ].filter(line => line.value !== undefined && line.value !== "" && (root.showMore || !line.more))

                delegate: Item {
                    id: line

                    required property var modelData
                    required property int index

                    width: details.width
                    height: Tokens.filesPreviewRowHeight
                    Accessible.role: Accessible.StaticText
                    Accessible.name: line.modelData.label + " " + line.modelData.value

                    // A hairline above every row but the first (macOS 27 Finder).
                    Rectangle {
                        visible: line.index > 0
                        width: parent.width
                        height: Tokens.appsBorderWidth
                        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                    }

                    Text {
                        id: lineLabel
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        width: Tokens.filesInfoLabelWidth
                        text: line.modelData.label
                        elide: Text.ElideRight
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }

                    Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        x: lineLabel.width + Tokens.spacingSm
                        width: parent.width - x
                        horizontalAlignment: Text.AlignRight
                        text: line.modelData.value
                        elide: Text.ElideMiddle
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }

            Item {
                width: 1
                height: Tokens.filesPreviewTagsGap
                visible: tagsBlock.visible
            }

            // Tags: the item's tags and a field that adds one (macOS 27: "Add Tags…"). Return adds what was typed (a
            // colour's name is that colour tag), Backspace in the empty field removes the last tag of a single item.
            Column {
                id: tagsBlock
                width: parent.width
                visible: root.taggable

                readonly property var keys: root.selectedCount <= 1 && root.info && root.info.tagKeys ? root.info.tagKeys : []
                readonly property var names: root.selectedCount <= 1 && root.info && root.info.tags ? root.info.tags : []

                Item {
                    width: parent.width
                    height: Tokens.filesPreviewRowHeight

                    Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Tags")
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        font.weight: Tokens.typographyMenuBoldWeight
                        Accessible.role: Accessible.Heading
                        Accessible.name: text
                    }
                }

                Item {
                    width: 1
                    height: Tokens.filesPreviewTagsFieldGap
                }

                Rectangle {
                    width: parent.width
                    height: Tokens.filesPreviewTagsFieldHeight
                    color: Appearance.colors.windowBackground

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.IBeamCursor
                        onClicked: tagInput.forceActiveFocus()
                    }

                    Row {
                        id: tagRow
                        width: parent.width
                        height: tagInput.implicitHeight
                        spacing: Tokens.spacingXs

                        TagDots {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: colors.length > 0
                            colors: root.selectedCount <= 1 && root.info && root.info.tagColors ? root.info.tagColors : []
                        }

                        Text {
                            id: tagNames
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                            visible: text !== ""
                            width: Math.min(implicitWidth, tagRow.width / 2)
                            text: tagsBlock.names.join(", ")
                            elide: Text.ElideRight
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }

                        TextInput {
                            id: tagInput
                            objectName: "previewTagInput"
                            width: tagRow.width - x
                            clip: true
                            color: Appearance.colors.text
                            selectionColor: Appearance.highlight
                            selectedTextColor: Appearance.highlightText
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            selectByMouse: true
                            Accessible.role: Accessible.EditableText
                            Accessible.name: qsTr("Add Tags")

                            Text {
                                textFormat: Text.PlainText
                                anchors.verticalCenter: parent.verticalCenter
                                visible: tagInput.text === "" && tagsBlock.names.length === 0
                                text: qsTr("Add Tags…")
                                color: Appearance.colors.textSecondary
                                font: tagInput.font
                            }

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    if (tagInput.text.trim() !== "")
                                        root.tab.app.addTypedTag(root.tagUrls, tagInput.text);
                                    tagInput.text = "";
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Backspace && tagInput.text === "" && tagsBlock.keys.length > 0) {
                                    root.tab.app.removeTag(root.tagUrls, tagsBlock.keys[tagsBlock.keys.length - 1]);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Escape) {
                                    tagInput.text = "";
                                    root.tab.focusView();
                                    event.accepted = true;
                                }
                            }
                        }
                    }

                    FocusRing {
                        shapeRadius: 0
                        visible: tagInput.activeFocus
                    }
                }
            }
        }
    }

    // Quick actions of the selection (macOS: Rotate Left, Markup, More…). Markup needs an annotation editor that
    // Grassfield does not have (docs/specs/preview.md non-goals), so it is not offered.
    Rectangle {
        id: actions
        visible: root.hasActions
        anchors.bottom: parent.bottom
        width: parent.width
        height: Tokens.filesPreviewActionsHeight
        color: Appearance.colors.windowBackground

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            y: Tokens.filesPreviewActionTop

            Repeater {
                model: [
                    {id: "rotateLeft", icon: "rotate-left", text: qsTr("Rotate Left")},
                    {id: "more", icon: "more-circle", text: qsTr("More…")}
                ]

                delegate: Item {
                    id: action

                    required property var modelData

                    width: (actions.width - 2 * Tokens.filesPreviewInset) / 3
                    height: actionColumn.implicitHeight
                    Accessible.role: Accessible.Button
                    Accessible.name: action.modelData.text
                    Accessible.onPressAction: root.runAction(action.modelData.id, action)

                    Column {
                        id: actionColumn
                        width: parent.width
                        spacing: Tokens.filesPreviewActionGap

                        Icon {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: action.modelData.icon
                            size: Tokens.filesPreviewActionIcon
                            color: actionMouse.pressed ? Appearance.colors.text : Appearance.colors.textSecondary
                        }

                        Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: action.modelData.text
                            elide: Text.ElideRight
                            color: actionMouse.pressed ? Appearance.colors.text : Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                        }
                    }

                    MouseArea {
                        id: actionMouse
                        anchors.fill: parent
                        onClicked: root.runAction(action.modelData.id, action)
                    }
                }
            }
        }
    }

    function runAction(id: string, anchor: Item): void {
        if (id === "rotateLeft") {
            root.tab.app.rotateImages(root.rotatable, false);
            return;
        }
        const p = anchor.mapToItem(null, 0, -Tokens.spacingXs);
        root.tab.win.menuLayer.open([{id: "rotateRight", text: qsTr("Rotate Right")}], p.x, p.y, chosen => {
            if (chosen === "rotateRight")
                root.tab.app.rotateImages(root.rotatable, true);
        }, root.tab.view, false);
    }
}
