pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A cards block (spec SR4): two cards per row at the reference width and more beyond the right edge, the next one peeking
// in the page's margin; one per row when the content is narrower than the reference. Arrows on hover, Left and Right keys.
FocusScope {
    id: root

    property var items: []

    signal opened(string id)

    readonly property int perPage: root.width >= Tokens.storeContentReferenceWidth ? 2 : 1
    readonly property real cardWidth: (root.width - (root.perPage - 1) * Tokens.storeCardGap) / root.perPage

    implicitHeight: Tokens.storeCardHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.List
    Accessible.name: qsTr("Stories")

    function step(delta: int): void {
        view.currentIndex = Math.max(0, Math.min(view.count - 1, view.currentIndex + delta));
        view.positionViewAtIndex(view.currentIndex, ListView.Contain);
    }

    Keys.onLeftPressed: root.step(-1)
    Keys.onRightPressed: root.step(1)
    Keys.onPressed: event => {
        if (ActivationKeys.activation(event.key) && view.currentItem) {
            root.opened(root.items[view.currentIndex].app.id);
            event.accepted = true;
        }
    }

    ListView {
        id: view
        width: root.width + Tokens.storeContentMargin
        height: root.height
        orientation: ListView.Horizontal
        spacing: Tokens.storeCardGap
        model: root.items
        snapMode: ListView.SnapToItem
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: Appearance.reduceMotion ? 0 : Tokens.storeCarouselMoveMs
        keyNavigationEnabled: false
        interactive: count > root.perPage

        delegate: StoryCard {
            id: card
            required property var modelData
            required property int index
            width: root.cardWidth
            height: view.height
            item: modelData
            onOpened: id => root.opened(id)

            FocusRing {
                shapeRadius: Tokens.storeCardRadius
                visible: root.activeFocus && view.currentIndex === card.index
            }
        }
    }

    HoverHandler {
        id: hover
    }

    CarouselArrow {
        x: Tokens.storeCarouselArrowInset
        anchors.verticalCenter: parent.verticalCenter
        back: true
        shown: hover.hovered && !view.atXBeginning
        onClicked: view.contentX = Math.max(view.originX, view.contentX - root.width - Tokens.storeCardGap)
    }

    CarouselArrow {
        x: root.width - width - Tokens.storeCarouselArrowInset
        anchors.verticalCenter: parent.verticalCenter
        shown: hover.hovered && !view.atXEnd && view.count > root.perPage
        onClicked: view.contentX = Math.min(view.contentWidth - view.width + view.originX, view.contentX + root.width + Tokens.storeCardGap)
    }
}
