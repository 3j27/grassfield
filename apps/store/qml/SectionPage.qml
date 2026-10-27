pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Discover and the catalog's other sections (spec SR2, SR4): the section's blocks in order: hero carousels, cards, rows.
// Without the catalog, Discover is the Store's own: one row per category, each with "See All".
ScrollPage {
    id: root

    required property var section

    signal opened(string id)
    signal categoryRequested(string id)

    title: root.section.builtIn ? qsTr("Discover") : root.section.title
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    Repeater {
        model: root.section.blocks

        delegate: Loader {
            id: block
            required property var modelData
            width: root.contentWidth
            sourceComponent: modelData.kind === "hero" ? hero : modelData.kind === "cards" ? cards : row

            Component {
                id: hero
                HeroCarousel {
                    cardWidth: root.contentWidth
                    items: block.modelData.items
                    onOpened: id => root.opened(id)
                }
            }

            Component {
                id: cards
                CardShelf {
                    items: block.modelData.items
                    onOpened: id => root.opened(id)
                }
            }

            Component {
                id: row
                Item {
                    implicitHeight: shelf.implicitHeight

                    AppShelf {
                        id: shelf
                        width: parent.width
                        title: block.modelData.title
                        apps: block.modelData.apps
                        onOpened: id => root.opened(id)
                    }

                    LinkText {
                        visible: (block.modelData.category || "") !== ""
                        anchors.right: parent.right
                        y: Math.round((shelf.titleHeight - height) / 2)
                        text: qsTr("See All")
                        target: block.modelData.title
                        onActivated: root.categoryRequested(block.modelData.category)
                    }
                }
            }
        }
    }
}
