pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TagColors.js" as TagColors

// Get Info: kind, size (folders are measured with KIO::directorySize), location, dates, and Sharing & Permissions: the
// owner, the group and everyone with the Finder's privilege pop-ups, editable for the user's own items (ADR-0028 option
// 1), the reason shown beside the padlock otherwise.
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

    title: qsTr("%1 Info").arg(DisplayName.text(root.info.name))
    width: Tokens.filesInfoWindowWidth
    height: Tokens.filesInfoWindowHeight
    minimumWidth: Tokens.filesInfoWindowWidth
    minimumHeight: Tokens.filesInfoWindowHeight / 2
    color: Appearance.windowFill
    visible: true

    onClosing: Qt.callLater(root.destroy)

    Component.onCompleted: {
        if (root.info.isDir && String(root.info.url).startsWith("grassfield-apps:")) {
            // The Applications location is no folder on disk: its size is the number of applications (the grid's list).
            const n = root.app.applicationsCount();
            root.folderSize = n === 1 ? qsTr("1 item") : qsTr("%1 items").arg(n);
        } else if (root.info.isDir) {
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

    // Only while this window is the key window: Qt also matches a window's Shortcuts while its transient parent (the
    // browser) has the keyboard, and Escape or Ctrl+W typed there closed Get Info or went astray.
    Shortcut {
        sequences: [StandardKey.Close, "Escape"]
        enabled: root.app.focusWindow === root
        onActivated: root.close()
    }

    // An application of the Applications location: what its desktop entry says, read-only.
    readonly property bool isApplication: root.info.isApplication === true

    readonly property var applicationRows: [
        {label: qsTr("Kind:"), value: root.info.kind},
        {label: qsTr("Category:"), value: root.info.genericName},
        {label: qsTr("Comment:"), value: root.info.comment},
        {label: qsTr("Where:"), value: DisplayName.text(root.info.where)},
        {label: qsTr("Desktop entry:"), value: root.info.desktopEntry},
        {label: qsTr("Command:"), value: root.info.command},
        {label: qsTr("Categories:"), value: root.info.categories},
        {header: qsTr("Sharing & Permissions")},
        {label: qsTr("You can:"), value: qsTr("Read only")}
    ]

    readonly property var rows: root.isApplication ? root.applicationRows : [
        {label: qsTr("Kind:"), value: root.info.kind},
        {label: qsTr("Size:"), value: root.info.isDir ? root.folderSize : qsTr("%1 (%2 bytes)").arg(root.info.sizeText).arg(root.info.bytes)},
        {label: qsTr("Where:"), value: DisplayName.text(root.info.where)},
        {label: qsTr("Created:"), value: root.info.created},
        {label: qsTr("Modified:"), value: root.info.modified},
        {label: qsTr("Opened:"), value: root.info.accessed},
        {label: qsTr("Link to:"), value: root.info.linkDest},
        {header: qsTr("Sharing & Permissions")},
        {label: qsTr("You can:"), value: root.info.writable ? qsTr("Read & Write") : root.info.readable ? qsTr("Read only") : qsTr("No Access")}
    ]

    // Open with (FP-65): the applications of the item's type, the default first chosen; Change All… makes the chosen one
    // the default for every document of the type (mimeapps.list). Files only, not folders or applications.
    readonly property bool openWithShown: !root.isApplication && !root.info.isDir && root.openWithApps.length > 0
    readonly property string mimeType: root.isApplication || root.info.isDir ? "" : root.app.mimeTypeOf(root.info.url)
    readonly property var openWithApps: root.mimeType !== "" ? root.app.applicationsFor([root.info.url]) : []
    property string defaultApp: root.mimeType !== "" ? root.app.defaultApplication(root.mimeType) : ""
    property string chosenApp: root.defaultApp

    // The item's owner, group and privileges, read again after each change (what the system reports).
    property var permissions: root.isApplication ? ({valid: false}) : root.app.permissionsOf(root.info.url)
    readonly property bool permissionsShown: !root.isApplication && root.permissions.valid === true
    readonly property var accessChoices: [
        {id: "3", text: qsTr("Read & Write")}, {id: "1", text: qsTr("Read only")}, {id: "2", text: qsTr("Write only")}, {id: "0", text: qsTr("No Access")}
    ]

    Connections {
        target: root.app
        function onPermissionsChanged(url: url): void {
            if (root.app.sameUrl(url, root.info.url))
                root.permissions = root.app.permissionsOf(root.info.url);
        }
    }

    // ADR-0015: the window draws its own chrome (the titlebar style of grassfield-ui); the apps' tagger
    // (apps/windowchrome.h) names its role for the compositor, whose plugin then draws no titlebar on it.
    property string gfChromeRole: "info"

    UnifiedToolbar {
        id: chrome
        width: parent.width
        window: root
        style: "titlebar"
        title: root.title
        doubleClickAction: root.app.titlebarDoubleClick
        canMinimize: root.app.canMinimize
    }

    Flickable {
        anchors.fill: parent
        anchors.topMargin: chrome.height
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
                    thumbnail: root.info.thumbnail || ""
                }

                Column {
                    width: parent.width - Tokens.filesInfoIconSize - Tokens.spacingMd
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Tokens.spacingXs

                    Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: DisplayName.text(root.info.name)
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
                        text: root.isApplication ? root.info.kind : root.info.isDir ? root.folderSize : root.info.sizeText
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
                visible: !root.isApplication
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
                        text: line.isHeader ? "" : (line.modelData.value ?? "")
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }

            Column {
                visible: root.openWithShown
                width: content.width
                spacing: Tokens.spacingXs

                Text {
                    textFormat: Text.PlainText
                    text: qsTr("Open with:")
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.weight: Tokens.typographyMenuBoldWeight
                    Accessible.role: Accessible.Heading
                    Accessible.name: text
                }

                ComboBox {
                    width: content.width
                    accessibleName: qsTr("Open with")
                    model: root.openWithApps.map(a => ({id: a.id, text: a.id === root.defaultApp ? qsTr("%1 (default)").arg(a.name) : a.name}))
                    value: root.chosenApp
                    onPicked: id => root.chosenApp = id
                }

                Text {
                    textFormat: Text.PlainText
                    width: content.width
                    wrapMode: Text.Wrap
                    text: qsTr("Use this application to open all documents like this one.")
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                Button {
                    text: qsTr("Change All…")
                    enabled: root.chosenApp !== "" && root.chosenApp !== root.defaultApp
                    onClicked: changeAllSheet.open()
                }
            }

            // Sharing & Permissions (Finder): Name and Privilege, one row each for the owner, the group and everyone.
            Column {
                visible: root.permissionsShown
                width: content.width
                spacing: Tokens.spacingXs
                Accessible.role: Accessible.Table
                Accessible.name: qsTr("Sharing & Permissions")

                Repeater {
                    model: root.permissionsShown ? [
                        {who: 0, name: root.permissions.ownedByMe ? qsTr("%1 (Me)").arg(root.permissions.owner) : root.permissions.owner},
                        {who: 1, name: root.permissions.group},
                        {who: 2, name: qsTr("everyone")}
                    ] : []

                    delegate: Item {
                        id: permissionRow
                        required property var modelData
                        width: content.width
                        height: privilege.implicitHeight
                        Accessible.role: Accessible.Row
                        Accessible.name: permissionRow.modelData.name

                        // The group's own pop-up: the user's groups (the item can be given to any of them).
                        ComboBox {
                            id: groupChoice
                            visible: permissionRow.modelData.who === 1 && root.permissions.editable && root.permissions.groups.length > 1
                            width: Tokens.filesInfoLabelWidth + Tokens.spacingLg
                            anchors.verticalCenter: parent.verticalCenter
                            accessibleName: qsTr("Group")
                            model: visible ? root.permissions.groups.map(g => ({id: g, text: g})) : []
                            value: root.permissions.group
                            onPicked: id => root.app.setGroup(root.info.url, id)
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: !groupChoice.visible
                            width: Tokens.filesInfoLabelWidth + Tokens.spacingLg
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: permissionRow.modelData.name
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                        }

                        ComboBox {
                            id: privilege
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            enabled: root.permissions.editable
                            accessibleName: qsTr("Privilege of %1").arg(permissionRow.modelData.name)
                            model: root.accessChoices
                            value: String(root.permissions.access[permissionRow.modelData.who])
                            onPicked: id => root.app.setAccess(root.info.url, permissionRow.modelData.who, parseInt(id))
                        }
                    }
                }

                // The padlock: closed with the reason when the item can't be changed here.
                Row {
                    visible: !root.permissions.editable
                    width: content.width
                    spacing: Tokens.spacingSm

                    Icon {
                        name: "lock"
                        size: Tokens.menuIconSize
                        color: Appearance.colors.textSecondary
                    }

                    Text {
                        textFormat: Text.PlainText
                        width: parent.width - Tokens.menuIconSize - Tokens.spacingSm
                        text: root.permissions.reason || ""
                        wrapMode: Text.Wrap
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    text: root.permissions.modeText || ""
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    Accessible.name: qsTr("Mode %1").arg(text)
                }

                Button {
                    visible: root.permissions.editable && root.permissions.isDir
                    text: qsTr("Apply to enclosed items…")
                    onClicked: applySheet.open()
                }
            }
        }
    }

    Sheet {
        id: changeAllSheet
        readonly property string appName: {
            for (let i = 0; i < root.openWithApps.length; i++) {
                if (root.openWithApps[i].id === root.chosenApp)
                    return root.openWithApps[i].name;
            }
            return "";
        }
        title: qsTr("Change all similar documents to open with “%1”?").arg(changeAllSheet.appName)
        message: qsTr("This change applies to all documents of this kind (%1).").arg(root.mimeType)
        confirmText: qsTr("Continue")
        confirmHandler: () => {
            if (!root.app.setDefaultApplication(root.mimeType, root.chosenApp))
                return qsTr("The default application couldn’t be changed.");
            root.defaultApp = root.app.defaultApplication(root.mimeType);
            return "";
        }
    }

    Sheet {
        id: applySheet
        title: qsTr("Apply these permissions to the items in “%1”?").arg(DisplayName.text(root.info.name))
        message: qsTr("The privileges of the owner, the group and everyone are given to everything in the folder. Folders, and files some class can already run, can be opened or run by those who can read them. Items that belong to someone else stay as they are.")
        confirmText: qsTr("OK")
        confirmHandler: () => {
            root.app.applyToEnclosed(root.info.url);
            return "";
        }
    }
}
