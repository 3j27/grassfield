pragma ComponentBehavior: Bound
import QtQuick
import QtTest

// Keyboard focus of the Notifications column's ListView (shell/notifications/NotificationCenter.qml): the view's own
// settings (currentIndex -1, no keyboard navigation) keep the focus on the focused card across inserts and removals
// at, above and below it. With the view's default current item the focus moved onto that delegate's root.
TestCase {
    id: tc
    name: "NotificationCenterListFocus"
    width: 200
    height: 400
    visible: true
    when: windowShown

    ListModel {
        id: rows
    }

    Component {
        id: viewComponent

        ListView {
            id: view

            property bool independent: true

            anchors.fill: parent
            model: rows
            currentIndex: independent ? -1 : 0
            highlightFollowsCurrentItem: !independent
            keyNavigationEnabled: !independent
            delegate: Column {
                id: del

                required property string key
                readonly property Item card: card

                width: view.width

                Item {
                    id: card

                    width: parent.width
                    height: 30
                    activeFocusOnTab: true
                }
            }
        }
    }

    function reset(n) {
        rows.clear();
        for (let i = n; i > 0; i--)
            rows.append({key: "k" + i});
    }

    function focusCard(view, key) {
        for (let i = 0; i < view.count; i++) {
            const it = view.itemAtIndex(i);
            if (it && it.key === key) {
                it.card.forceActiveFocus();
                return it.card;
            }
        }
        return null;
    }

    function holder(view) {
        for (let f = view.Window.activeFocusItem; f; f = f.parent) {
            if (f.card !== undefined)
                return f.key;
        }
        return "";
    }

    function make(independent) {
        reset(5);
        const view = createTemporaryObject(viewComponent, tc, {independent: independent});
        verify(view);
        tryCompare(view, "count", 5);
        return view;
    }

    function test_insertAboveKeepsFocus() {
        const view = make(true);
        verify(focusCard(view, "k3"));
        rows.insert(0, {key: "new1"});
        wait(50);
        compare(holder(view), "k3");
        rows.insert(1, {key: "new2"});
        wait(50);
        compare(holder(view), "k3");
    }

    function test_insertBelowKeepsFocus() {
        const view = make(true);
        verify(focusCard(view, "k2"));
        rows.append({key: "tail"});
        rows.insert(4, {key: "mid"});
        wait(50);
        compare(holder(view), "k2");
    }

    function test_removeOtherCardKeepsFocus() {
        const view = make(true);
        verify(focusCard(view, "k3"));
        rows.remove(0, 1);
        wait(50);
        compare(holder(view), "k3");
        rows.remove(3, 1);
        wait(50);
        compare(holder(view), "k3");
    }

    function test_moveKeepsFocus() {
        const view = make(true);
        verify(focusCard(view, "k4"));
        rows.move(4, 0, 1);
        wait(50);
        compare(holder(view), "k4");
    }

    function test_focusOnTheTopCardSurvivesAnArrival() {
        const view = make(true);
        verify(focusCard(view, "k1"));
        rows.insert(0, {key: "arrival"});
        wait(50);
        compare(holder(view), "k1");
    }

    function test_viewHasNoCurrentItem() {
        const view = make(true);
        compare(view.currentIndex, -1);
        rows.insert(0, {key: "arrival"});
        wait(50);
        compare(view.currentIndex, -1);
    }
}
