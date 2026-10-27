pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// Categories (spec SR8): a tile per category of the catalog (or the Store's own while there is none), its symbol and name;
// a click, Return or Space opens its list. The arrows move between tiles.
ScrollPage {
    id: root

    property var categories: []

    signal categoryRequested(string id)

    title: qsTr("Categories")
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    Grid {
        id: grid
        width: root.contentWidth
        columns: Math.max(1, Math.floor((width + columnSpacing) / (Tokens.storeCategoryMinWidth + columnSpacing)))
        columnSpacing: Tokens.storeCategoryGap
        rowSpacing: Tokens.storeCategoryGap
        readonly property real cellWidth: (width - (columns - 1) * columnSpacing) / columns

        function focusTile(index: int): void {
            const t = tiles.itemAt(Math.max(0, Math.min(root.categories.length - 1, index)));
            if (t)
                t.forceActiveFocus(Qt.TabFocusReason);
        }

        Repeater {
            id: tiles
            model: root.categories

            delegate: FocusScope {
                id: tile
                required property var modelData
                required property int index
                width: grid.cellWidth
                height: Tokens.storeCategoryHeight
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("%1, apps: %2").arg(modelData.title).arg(modelData.count)
                Accessible.onPressAction: root.categoryRequested(modelData.id)
                Keys.onPressed: event => {
                    if (ActivationKeys.activation(event.key)) {
                        root.categoryRequested(tile.modelData.id);
                        event.accepted = true;
                    }
                }
                Keys.onLeftPressed: grid.focusTile(index - 1)
                Keys.onRightPressed: grid.focusTile(index + 1)
                Keys.onUpPressed: grid.focusTile(index - grid.columns)
                Keys.onDownPressed: grid.focusTile(index + grid.columns)

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.storeCategoryRadius
                    color: Appearance.colors.groupFill

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
                        visible: hover.hovered
                    }
                }

                FocusRing {
                    shapeRadius: Tokens.storeCategoryRadius
                    visible: tile.activeFocus
                }

                Icon {
                    id: glyph
                    x: Tokens.storeCategoryInset
                    anchors.verticalCenter: parent.verticalCenter
                    name: Store.symbolIcon(tile.modelData.symbol)
                    size: Tokens.storeCategoryIconSize
                    color: Appearance.colors.accent
                }

                Text {
                    anchors.left: glyph.right
                    anchors.leftMargin: Tokens.storeCategoryInset
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.storeCategoryInset
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: tile.modelData.title
                    elide: Text.ElideRight
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.storeCategoryTextSize
                    font.weight: Tokens.storeLockupNameWeight
                    font.letterSpacing: Appearance.tracking(Tokens.storeCategoryTextSize)
                }

                HoverHandler {
                    id: hover
                }

                TapHandler {
                    onTapped: root.categoryRequested(tile.modelData.id)
                }
            }
        }
    }
}
