pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui

// Icon of an Apps item: the application icon, or a folder tile with up to nine mini icons.
// `info` is a display item: {kind: "app", rec} | {kind: "folder", apps: [item]} | {kind: "none"}.
Item {
    id: root

    required property var info
    property real size: Tokens.appsIconSize

    readonly property bool isFolder: info.kind === "folder"
    readonly property int miniCols: Tokens.appsFolderMiniCols
    readonly property real pad: size * Tokens.appsFolderPadding
    readonly property real miniSize: (size - 2 * pad - (miniCols - 1) * Tokens.spacingXs) / miniCols

    width: size
    height: size

    Image {
        anchors.fill: parent
        visible: root.info.kind === "app"
        source: root.info.kind === "app" ? Quickshell.iconPath(root.info.rec.icon, "application-x-executable") : ""
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
    }

    Rectangle {
        anchors.fill: parent
        visible: root.isFolder
        radius: root.size * Tokens.appsFolderRadiusScale
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2)
        border.width: 1
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
    }

    Grid {
        x: root.pad
        y: root.pad
        columns: root.miniCols
        spacing: Tokens.spacingXs
        visible: root.isFolder

        Repeater {
            model: root.isFolder ? Math.min(root.miniCols * root.miniCols, root.info.apps.length) : 0

            Image {
                id: mini

                required property int index

                width: root.miniSize
                height: root.miniSize
                source: Quickshell.iconPath(root.info.apps[index].rec.icon, "application-x-executable")
                sourceSize: Qt.size(root.miniSize * 2, root.miniSize * 2)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                smooth: true
            }
        }
    }
}
