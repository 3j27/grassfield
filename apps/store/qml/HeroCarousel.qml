pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The hero block (spec SR4): one card per page, the next one peeking in the page's right margin; arrows on hover, the
// Left and Right keys, never an automatic turn (Reduce Motion or not); Return opens the shown card's app.
FocusScope {
    id: root

    property var items: []
    // The page's content width: one card's width.
    property real cardWidth: width

    signal opened(string id)

    implicitHeight: Tokens.storeHeroHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.List
    Accessible.name: qsTr("Featured")

    function step(delta: int): void {
        view.currentIndex = Math.max(0, Math.min(view.count - 1, view.currentIndex + delta));
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
        // Past the content's right edge, into the page's margin: the next card peeks there (macOS 27).
        width: root.width + Tokens.storeContentMargin
        height: root.height
        orientation: ListView.Horizontal
        spacing: Tokens.storeHeroGap
        model: root.items
        snapMode: ListView.SnapOneItem
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: root.cardWidth
        highlightMoveDuration: Appearance.reduceMotion ? 0 : Tokens.storeCarouselMoveMs
        boundsBehavior: Flickable.StopAtBounds
        interactive: count > 1
        keyNavigationEnabled: false

        delegate: HeroCard {
            required property var modelData
            width: root.cardWidth
            height: view.height
            item: modelData
            onOpened: id => root.opened(id)
        }
    }

    // The keyboard's ring around the shown card.
    Item {
        width: root.cardWidth
        height: root.height

        FocusRing {
            shapeRadius: Tokens.storeHeroRadius
            visible: root.activeFocus
        }
    }

    HoverHandler {
        id: hover
    }

    CarouselArrow {
        x: Tokens.storeCarouselArrowInset
        anchors.verticalCenter: parent.verticalCenter
        back: true
        shown: hover.hovered && view.currentIndex > 0
        onClicked: root.step(-1)
    }

    CarouselArrow {
        x: root.cardWidth - width - Tokens.storeCarouselArrowInset
        anchors.verticalCenter: parent.verticalCenter
        shown: hover.hovered && view.currentIndex < view.count - 1
        onClicked: root.step(1)
    }
}
