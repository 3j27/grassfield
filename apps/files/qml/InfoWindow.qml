pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TagColors.js" as TagColors
import "Nav.js" as Nav

// Get Info: kind, size (folders are measured with KIO::directorySize), location, dates and the
// owner, group and permissions (read only in v1).
Window {
    id: root

    required property var app
    // FolderModel.info() map.
    required property var info

    property string folderSize: ""

    // Tags, read again whenever Files writes tags (FilesApp.tagRevision).
    readonly property string tagsReason: {
        root.app.tagRevision;
        return root.app.tagsUnavailable([root.info.url]);
    }
    readonly property var tagStates: {
        root.app.tagRevision;
        // Also for a read-only item: its tags show (disabled swatches), only changing them is refused.
        return root.app.colorTagStates([root.info.url]);
    }
    // Every tag of the item by name, those of other applications too (the swatches show the colour ones). Read live:
    // `info` is the snapshot taken when the window opened.
    readonly property string tagNames: {
        root.app.tagRevision;
        return root.app.tagNamesOf(root.info.url).join(", ");
    }

    // The folder's own look, read again whenever Files writes one (FilesApp.folderStyleRevision).
    readonly property var folderStyle: {
        root.app.folderStyleRevision;
        return root.info.isDir ? root.app.folderStyleOf(root.info.url) : {color: "", glyph: ""};
    }
    readonly property string customizeReason: root.info.isDir ? root.app.folderStyleUnavailable([root.info.url]) : "x"

    title: qsTr("%1 Info").arg(Nav.displayName(root.info.name))
    width: Tokens.filesInfoWindowWidth
    height: Tokens.filesInfoWindowHeight
    minimumWidth: Tokens.filesInfoWindowWidth
    minimumHeight: Tokens.filesInfoWindowHeight / 2
    color: Appearance.colors.materialTint
    visible: true

    onClosing: Qt.callLater(root.destroy)

    Component.onCompleted: {
        if (root.info.isDir) {
            root.folderSize = qsTr("Calculating…");
            root.app.directorySize(root.info.url, (bytes, files, folders) => {
                const n = files + folders;
                const size = root.app.formatSize(bytes);
                root.folderSize = bytes < 0 ? qsTr("Unknown") : n === 1 ? qsTr("%1 for 1 item").arg(size) : qsTr("%1 for %2 items").arg(size).arg(n);
            });
        }
    }

    // Opened by the browser window that owns this one.
    property var browser: null

    function customize(): void {
        if (root.browser)
            root.browser.customizeFolders([root.info.url], root.info.name, root.info.iconName);
    }

    Shortcut {
        sequences: [StandardKey.Close, "Escape"]
        onActivated: root.close()
    }

    readonly property var rows: [
        {label: qsTr("Kind:"), value: root.info.kind},
        {label: qsTr("Size:"), value: root.info.isDir ? root.folderSize : qsTr("%1 (%2 bytes)").arg(root.info.sizeText).arg(root.info.bytes)},
        {label: qsTr("Where:"), value: root.info.where},
        {label: qsTr("Created:"), value: root.info.created},
        {label: qsTr("Modified:"), value: root.info.modified},
        {label: qsTr("Opened:"), value: root.info.accessed},
        {label: qsTr("Link to:"), value: root.info.linkDest},
        {header: qsTr("Sharing & Permissions")},
        {label: qsTr("Owner:"), value: root.info.owner},
        {label: qsTr("Group:"), value: root.info.group},
        {label: qsTr("Permissions:"), value: root.info.permissions},
        {label: qsTr("You can:"), value: root.info.writable ? qsTr("Read & Write") : root.info.readable ? qsTr("Read only") : qsTr("No Access")}
    ]

    Flickable {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        contentHeight: content.implicitHeight + 2 * Tokens.spacingLg
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: content
            x: Tokens.spacingLg
            y: Tokens.spacingLg
            width: parent.width - 2 * Tokens.spacingLg
            spacing: Tokens.spacingSm

            Row {
                spacing: Tokens.spacingMd
                width: parent.width

                FileIcon {
                    size: Tokens.filesInfoIconSize
                    iconName: root.info.iconName
                    isDir: root.info.isDir
                    folderColor: root.folderStyle.color
                    folderGlyph: root.folderStyle.glyph
                    thumbnail: root.info.thumbnail
                }

                Column {
                    width: parent.width - Tokens.filesInfoIconSize - Tokens.spacingMd
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Tokens.spacingXs

                    Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: Nav.displayName(root.info.name)
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
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
                        text: root.info.isDir ? root.folderSize : root.info.sizeText
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }

            // Folders: the colour and symbol of this folder (the same window as the context menu's). Under the name, on the
            // full width of the panel: the button sizes to its text, whatever the language (the French label is long).
            Button {
                visible: root.info.isDir
                height: visible ? implicitHeight : 0
                text: qsTr("Customize Folder…")
                enabled: root.customizeReason === ""
                onClicked: root.customize()
            }

            Rectangle {
                width: parent.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            // Colour tags of the item: a click adds or removes one (user.xdg.tags). Items that can't carry tags (remote,
            // in the Trash, links, volumes without extended attributes) show the row disabled, the reason under it and
            // in a tooltip.
            Item {
                id: tagLine
                width: content.width
                height: tagSwatches.implicitHeight
                Accessible.role: Accessible.Grouping
                Accessible.name: tagLabel.text

                Text {
                    id: tagLabel
                    textFormat: Text.PlainText
                    width: Tokens.filesInfoLabelWidth
                    y: Tokens.spacingXs
                    horizontalAlignment: Text.AlignRight
                    text: qsTr("Tags:")
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                SwatchRow {
                    id: tagSwatches
                    x: Tokens.filesInfoLabelWidth + Tokens.spacingSm - Tokens.menuItemPadding
                    width: parent.width - x
                    enabled: root.tagsReason === ""
                    caption: root.tagsReason === "" ? root.tagNames : root.tagNames === "" ? root.tagsReason : qsTr("%1 (%2)").arg(root.tagNames).arg(root.tagsReason)
                    accessibleName: qsTr("Tags")
                    model: TagColors.swatches(Tokens, root.app.colorTagNames, root.tagStates)
                    onChosen: index => root.app.toggleColorTag([root.info.url], index)
                }

                HoverHandler {
                    id: tagHover
                }

                Tooltip {
                    text: root.tagsReason
                    shown: tagHover.hovered && root.tagsReason !== ""
                    x: tagSwatches.x
                    y: -height - Tokens.spacingXs
                    z: 1
                }
            }

            Repeater {
                model: root.rows

                delegate: Item {
                    id: line
                    required property var modelData
                    readonly property bool isHeader: line.modelData.header !== undefined

                    width: content.width
                    visible: line.isHeader || (line.modelData.value !== undefined && line.modelData.value !== "")
                    height: visible ? Math.max(labelText.implicitHeight, valueText.implicitHeight) + (line.isHeader ? Tokens.spacingMd : 0) : 0
                    Accessible.role: line.isHeader ? Accessible.Heading : Accessible.StaticText
                    Accessible.name: line.isHeader ? line.modelData.header : line.modelData.label + " " + line.modelData.value

                    Text {
                        id: labelText
                        textFormat: Text.PlainText
                        // Headers sit at the bottom of their taller row; labels align with the first value line.
                        y: line.isHeader ? line.height - implicitHeight : 0
                        width: line.isHeader ? parent.width : Tokens.filesInfoLabelWidth
                        horizontalAlignment: line.isHeader ? Text.AlignLeft : Text.AlignRight
                        text: line.isHeader ? line.modelData.header : line.modelData.label
                        color: line.isHeader ? Appearance.colors.text : Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                        font.weight: line.isHeader ? Tokens.typographyMenuBoldWeight : Tokens.typographySmallWeight
                    }

                    Text {
                        id: valueText
                        textFormat: Text.PlainText
                        visible: !line.isHeader
                        x: Tokens.filesInfoLabelWidth + Tokens.spacingSm
                        width: parent.width - x
                        text: line.isHeader ? "" : line.modelData.value
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }
        }
    }
}
