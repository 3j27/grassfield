pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services
import "DockModel.js" as DockModel
import "Stacks.js" as Stacks

// Icon of one item of a folder stack (docs/specs/dock.md requirement 25): a real preview for pictures (drawn from the
// file, like macOS' thumbnails in a stack), otherwise the icon theme's icon of its type in the user's icon mode.
Item {
    id: root

    property string path: ""
    property bool isDir: false
    property int size: Tokens.dockStackIconSize

    readonly property string mime: {
        if (root.isDir)
            return "inode/directory";
        const data = Apps.mimeData;
        if (!data || !data.ready)
            return "";
        const types = DockModel.mimeTypesOf(root.path, data);
        return types.length > 0 ? types[0] : "";
    }
    readonly property bool preview: !root.isDir && Stacks.hasPreview(root.mime)
    readonly property string themed: {
        for (const name of Stacks.iconCandidates(root.mime, root.isDir)) {
            const found = Quickshell.iconPath(name, true);
            if (found !== "")
                return found;
        }
        return Quickshell.iconPath("text-x-generic", "");
    }

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    Image {
        anchors.fill: parent
        visible: root.preview
        source: root.preview ? Stacks.fileUrl(root.path) : ""
        asynchronous: true
        cache: false
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        smooth: true
    }

    TintedIcon {
        anchors.fill: parent
        visible: !root.preview
        size: root.size
        source: root.preview ? "" : root.themed
    }
}
