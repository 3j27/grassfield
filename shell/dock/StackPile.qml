pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.folderlistmodel
import Grassfield.Ui
import "Stacks.js" as Stacks

// The tile of a folder stack shown as a stack (macOS "Display as: Stack"): the newest items of the folder piled up, the
// newest on top, the ones behind turned a few degrees. Live (the folder is watched), and read only. An empty folder shows
// the folder icon instead (`empty`).
Item {
    id: root

    property string folder: ""
    property int size: Tokens.dockIconSize
    // The folder has no visible item.
    readonly property bool empty: listing.count === 0
    readonly property real sheet: root.size * Tokens.dockStackPileScale

    FolderListModel {
        id: listing
        folder: root.folder !== "" ? Stacks.fileUrl(root.folder) : ""
        sortField: FolderListModel.Time
        sortReversed: true
        showDirs: true
        showFiles: true
        showHidden: false
        showDotAndDotDot: false
    }

    Repeater {
        // Back to front: the third, the second, the newest.
        model: Math.min(3, listing.count)

        delegate: Item {
            id: sheetItem

            required property int index
            readonly property int rank: Math.min(3, listing.count) - 1 - index
            readonly property int at: rank
            readonly property string filePath: listing.get(at, "filePath") ?? ""
            readonly property bool dir: listing.get(at, "fileIsDir") === true

            width: root.sheet
            height: root.sheet
            anchors.centerIn: parent
            anchors.verticalCenterOffset: root.size * (rank === 0 ? 0.04 : 0)
            rotation: rank === 0 ? 0 : (rank === 1 ? -Tokens.dockStackPileTilt : Tokens.dockStackPileTilt)

            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusControl
                color: Appearance.colors.fieldFill
                border.width: 1
                border.color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.materialFillOpacity)
            }

            StackIcon {
                anchors.centerIn: parent
                path: sheetItem.filePath
                isDir: sheetItem.dir
                size: Math.round(root.sheet * 0.8)
            }
        }
    }
}
