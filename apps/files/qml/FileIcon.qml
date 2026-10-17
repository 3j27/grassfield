import QtQuick
import Grassfield.Ui

// A file's picture: its KIO thumbnail when one exists, else the theme icon for its type, plus the
// symbolic-link emblem.
Item {
    id: root

    property string iconName: ""
    property string thumbnail: ""
    property string emblem: ""
    property int size: Tokens.filesIconSize

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    ThemeIcon {
        anchors.fill: parent
        size: root.size
        name: root.iconName
        tint: false
        visible: thumb.status !== Image.Ready
    }

    Image {
        id: thumb
        anchors.centerIn: parent
        width: Math.min(root.size, implicitWidth)
        height: Math.min(root.size, implicitHeight)
        source: root.thumbnail
        sourceSize: Qt.size(root.size * Tokens.filesThumbnailOversample, root.size * Tokens.filesThumbnailOversample)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        visible: status === Image.Ready

        // Thin frame so light thumbnails stay distinct from the window background.
        Rectangle {
            anchors.centerIn: parent
            width: thumb.paintedWidth + 2 * Tokens.appsBorderWidth
            height: thumb.paintedHeight + 2 * Tokens.appsBorderWidth
            color: "transparent"
            border.width: Tokens.appsBorderWidth
            border.color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
        }
    }

    ThemeIcon {
        visible: root.emblem !== ""
        name: root.emblem
        size: Math.max(Tokens.filesListIconSize / 2, Math.min(Tokens.filesEmblemSize, root.size / 2))
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        tint: false
    }
}
