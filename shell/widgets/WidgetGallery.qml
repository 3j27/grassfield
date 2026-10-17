pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// "Edit Widgets" gallery: every available widget with a live preview, a size picker and
// Add (Notification Center) / Add to Desktop. Esc or Done closes it. Keyboard: Tab walks the
// size segments and buttons, Space or Return activates.
FocusScope {
    id: root

    // Output the "Add to Desktop" button places the widget on.
    property string screenName: ""

    signal closed

    property string note: ""

    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Widget gallery")
    Keys.onEscapePressed: root.closed()

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusPanel
        color: Appearance.withAlpha(Appearance.colors.materialTint, Math.max(Appearance.tintAlpha(Appearance.effectiveTransparency), Tokens.materialBodyOpacity))
    }

    // Swallows clicks on the gallery.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
    }

    Item {
        id: header
        x: Tokens.spacingLg
        y: Tokens.spacingLg
        width: parent.width - 2 * Tokens.spacingLg
        height: done.implicitHeight

        WidgetLabel {
            anchors.verticalCenter: parent.verticalCenter
            text: qsTr("Widgets")
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        Button {
            id: done
            anchors.right: parent.right
            primary: true
            focus: true
            text: qsTr("Done")
            onClicked: root.closed()
        }
    }

    WidgetLabel {
        id: noteLabel
        x: Tokens.spacingLg
        y: parent.height - height - Tokens.spacingMd
        width: parent.width - 2 * Tokens.spacingLg
        height: implicitHeight
        text: root.note
        color: Appearance.colors.textSecondary
        font.pixelSize: Tokens.typographyCaptionSize
        Accessible.role: Accessible.StaticText
        Accessible.name: root.note
    }

    ListView {
        id: list
        x: Tokens.spacingLg
        y: header.y + header.height + Tokens.spacingMd
        width: parent.width - 2 * Tokens.spacingLg
        height: noteLabel.y - y - Tokens.spacingSm
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        spacing: Tokens.spacingLg
        cacheBuffer: height
        model: Registry.manifests.filter(m => Widgets.available(m.id))

        delegate: Column {
            id: row

            required property var modelData
            property string pickedSize: modelData.sizes[0]
            readonly property real previewScale: Math.min(1, Tokens.widgetGalleryRowHeight / preview.height, list.width / preview.width)

            width: list.width
            spacing: Tokens.spacingSm

            Item {
                width: parent.width
                height: Math.min(Tokens.widgetGalleryRowHeight, preview.height * row.previewScale)

                WidgetHost {
                    id: preview
                    entry: ({
                            uid: "preview",
                            id: row.modelData.id,
                            size: row.pickedSize
                        })
                    cell: Tokens.widgetCell
                    flat: true
                    interactive: false
                    scale: row.previewScale
                    transformOrigin: Item.Top
                    x: (parent.width - width) / 2
                }
            }

            WidgetLabel {
                width: parent.width
                text: Registry.title(row.modelData.id)
                font.weight: Tokens.typographyMenuBoldWeight
            }

            SizePicker {
                sizes: row.modelData.sizes
                current: row.pickedSize
                onPicked: size => row.pickedSize = size
            }

            Row {
                spacing: Tokens.spacingSm

                Button {
                    text: qsTr("Add")
                    Accessible.name: qsTr("Add %1 to Notification Center").arg(Registry.title(row.modelData.id))
                    onClicked: {
                        Widgets.addCenter(row.modelData.id, row.pickedSize);
                        root.note = qsTr("%1 added to the Notification Center.").arg(Registry.title(row.modelData.id));
                    }
                }

                Button {
                    text: qsTr("Add to Desktop")
                    Accessible.name: qsTr("Add %1 to the desktop").arg(Registry.title(row.modelData.id))
                    onClicked: {
                        const ok = Widgets.addDesktop(row.modelData.id, row.pickedSize, root.screenName);
                        root.note = ok ? qsTr("%1 added to the desktop.").arg(Registry.title(row.modelData.id)) : qsTr("There is no room left on the desktop.");
                    }
                }
            }
        }
    }
}
