pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Path bar: the location as clickable segments (home or the root first). Segments accept drops.
Item {
    id: root

    property var tab: null

    implicitHeight: Tokens.filesPathBarHeight
    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Path")

    Rectangle {
        width: parent.width
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
    }

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.leftMargin: Tokens.spacingSm
        anchors.rightMargin: Tokens.spacingSm
        contentWidth: row.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        // Keep the deepest segment visible.
        onContentWidthChanged: contentX = Math.max(0, contentWidth - width)

        Row {
            id: row
            height: flick.height
            spacing: Tokens.spacingXs

            Repeater {
                model: root.tab ? root.tab.segments : []

                delegate: Row {
                    id: segment
                    required property var modelData
                    required property int index
                    readonly property bool last: root.tab && segment.index === root.tab.segments.length - 1

                    height: row.height
                    spacing: Tokens.spacingXs

                    Icon {
                        visible: segment.index > 0
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-right"
                        size: Tokens.filesChevronSize
                        color: Appearance.colors.textSecondary
                    }

                    Item {
                        width: label.implicitWidth + 2 * Tokens.spacingXs
                        height: parent.height
                        Accessible.role: Accessible.Button
                        Accessible.name: segment.modelData.label
                        Accessible.onPressAction: root.tab.navigate(segment.modelData.url, true)

                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: Tokens.spacingXs
                            anchors.bottomMargin: Tokens.spacingXs
                            radius: Tokens.radiusControl
                            color: mouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                            border.width: drop.containsDrag ? Tokens.filesDropBorder : 0
                            border.color: Appearance.colors.accent
                        }

                        Text {
                            id: label
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: segment.modelData.label
                            color: segment.last ? Appearance.colors.text : Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                            font.weight: segment.last ? Tokens.typographyMenuWeight : Tokens.typographySmallWeight
                        }

                        DropArea {
                            id: drop
                            anchors.fill: parent
                            keys: ["text/uri-list"]
                            onDropped: event => {
                                if (event.hasUrls) {
                                    root.tab.dropUrls(event.urls, segment.modelData.url, null);
                                    event.accept(Qt.CopyAction);
                                }
                            }
                        }

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.tab.navigate(segment.modelData.url, true)
                        }
                    }
                }
            }
        }
    }
}
