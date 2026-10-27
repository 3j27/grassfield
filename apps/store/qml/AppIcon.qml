import QtQuick
import Grassfield.Ui

// An app's icon (spec SR5): its file from AppStream or our catalog, decoded off the GUI thread at twice its size; while it
// loads, and for an app without one, the generic glyph on a quiet tile of the icon's shape.
Item {
    id: root

    property string source: ""
    property real size: Tokens.storeLockupIconSize

    implicitWidth: root.size
    implicitHeight: root.size
    Accessible.ignored: true

    Rectangle {
        anchors.fill: parent
        visible: image.status !== Image.Ready
        radius: root.size * Tokens.storeIconRadiusRatio
        color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)

        Icon {
            anchors.centerIn: parent
            name: "apps"
            size: Math.round(root.size * Tokens.storeIconPlaceholderGlyphRatio)
            color: Appearance.windowSecondary
        }
    }

    Image {
        id: image
        anchors.fill: parent
        source: root.source
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        asynchronous: true
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        visible: status === Image.Ready
    }
}
