pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// Files' sidebar eject: with the toolbar buttons out of the Tab chain, the keyboard reaches Eject through File > Eject (Ctrl+E)
// and the sidebar item's context menu (macOS Finder). Sidebar.ejectRow names the volume the sidebar points at (the row
// the keyboard is on while the sidebar has the focus, else the one whose folder is shown); it is -1 for anything else.
TestCase {
    id: tc

    name: "FilesSidebar"
    width: 400
    height: 400
    visible: true
    when: windowShown

    property var ejected: []
    property var menus: []

    ListModel {
        id: placesItem

        property string current: "file:///media/usb"

        ListElement {
            section: "favorites"
            name: "Home"
            url: "file:///home/u"
            iconName: "user-home"
            kind: "folder"
            mounted: true
            ejectable: false
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        ListElement {
            section: "locations"
            name: "USB"
            url: "file:///media/usb"
            iconName: "drive-removable-media"
            kind: "volume"
            mounted: true
            ejectable: true
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        ListElement {
            section: "locations"
            name: "Busy disk"
            url: "file:///media/busy"
            iconName: "drive-removable-media"
            kind: "volume"
            mounted: true
            ejectable: true
            busy: true
            tag: ""
            tagColor: -1
            unavailable: false
        }

        // Last here so the rows above keep their numbers (first in the real sidebar).
        ListElement {
            section: "favorites"
            name: "Applications"
            url: "grassfield-apps:/"
            iconName: "folder-applications"
            kind: "applications"
            mounted: true
            ejectable: false
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        ListElement {
            section: "recents"
            name: "Recents"
            url: "grassfield-recents:/"
            iconName: "document-open-recent"
            kind: "recents"
            mounted: true
            ejectable: false
            busy: false
            tag: ""
            tagColor: -1
            unavailable: false
        }

        function rowForUrl(url): int {
            for (let i = 0; i < placesItem.count; i++) {
                if (String(placesItem.get(i).url) === String(url))
                    return i;
            }
            return -1;
        }
        function eject(row: int): void {
            tc.ejected = tc.ejected.concat([row]);
        }
        function mount(row: int): void {
        }
    }

    QtObject {
        id: fakeApp

        property var places: placesItem
        property var hiddenTags: []
    }

    QtObject {
        id: fakeTab

        property var url: "file:///media/usb"
        property var win: QtObject {
            property var menuLayer: QtObject {
                function open(items, x, y, cb, back, flag): void {
                    tc.menus = tc.menus.concat([{items: items, cb: cb}]);
                }
            }
        }
        property var navigated: []
        function navigate(url, record): void {
            fakeTab.navigated = fakeTab.navigated.concat([String(url)]);
        }
        property var hovered: []
        function springHover(url): void {
            fakeTab.hovered = fakeTab.hovered.concat([String(url)]);
        }
        function springLeave(url): void {
        }
    }

    // A drag from elsewhere (Drag.Internal: delivered within this window, like the system drag reaches the DropAreas).
    Item {
        id: incoming
        width: 4
        height: 4
        z: 10
        Drag.keys: ["text/uri-list"]
        Drag.dragType: Drag.Internal
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.hotSpot.x: 2
        Drag.hotSpot.y: 2
    }

    Sidebar {
        id: sidebar

        width: 200
        height: 300
        app: fakeApp
        tab: fakeTab
    }

    function init() {
        tc.ejected = [];
        tc.menus = [];
        fakeTab.url = "file:///media/usb";
        tc.forceActiveFocus();
        sidebar.keyRow = -1;
        tryCompare(sidebar, "ejectRow", 1);
    }

    function test_theVolumeShownIsTheEjectTarget() {
        compare(sidebar.ejectRow, 1);
        verify(sidebar.eject());
        compare(tc.ejected, [1]);
    }

    function test_aFolderBusyOrUnknownRowIsNoTarget() {
        fakeTab.url = "file:///home/u";
        tryCompare(sidebar, "ejectRow", -1);
        verify(!sidebar.eject());
        fakeTab.url = "file:///media/busy";
        tryCompare(sidebar, "ejectRow", -1);
        verify(!sidebar.eject());
        compare(tc.ejected, [], "nothing was ejected");
    }

    function test_theKeyboardRowWinsWhileTheSidebarHasTheFocus() {
        fakeTab.url = "file:///home/u";
        sidebar.forceActiveFocus();
        sidebar.keyRow = 1;
        tryCompare(sidebar, "ejectRow", 1);
        sidebar.keyRow = 0;
        tryCompare(sidebar, "ejectRow", -1);
        sidebar.keyRow = 2;
        tryCompare(sidebar, "ejectRow", -1, 1000, "a busy volume is not ejected twice");
    }

    // The context menu of an ejectable volume row offers Eject, and it ejects that row.
    function test_contextMenuOfAVolumeRowOffersEject() {
        // The row of "USB": click it with the right button through the list item.
        const listView = findList(sidebar);
        verify(listView !== null);
        const item = listView.itemAtIndex(1);
        verify(item !== null);
        mouseClick(item, 20, item.height / 2, Qt.RightButton);
        compare(tc.menus.length, 1);
        compare(tc.menus[0].items.map(i => i.text), ["Eject"]);
        tc.menus[0].cb("eject");
        compare(tc.ejected, [1]);
        // A folder row and a busy volume row have no menu.
        mouseClick(listView.itemAtIndex(0), 20, 8, Qt.RightButton);
        mouseClick(listView.itemAtIndex(2), 20, 8, Qt.RightButton);
        compare(tc.menus.length, 1);
    }

    // Recents takes no drop and does not spring open (Finder); a folder place takes the drag and springs.
    function test_recentsTakesNoDrop() {
        const listView = findList(sidebar);
        verify(listView !== null);
        fakeTab.hovered = [];
        for (const row of [{index: 4, accepted: false}, {index: 0, accepted: true}]) {
            const item = listView.itemAtIndex(row.index);
            verify(item !== null);
            const p = item.mapToItem(tc, item.width / 2, item.height / 2);
            incoming.x = p.x - 2;
            incoming.y = p.y - 2;
            incoming.Drag.active = true;
            incoming.y += 1;
            wait(20);
            if (row.accepted)
                verify(incoming.Drag.target !== null, "Home takes the drag");
            else
                compare(incoming.Drag.target, null, "Recents takes no drag");
            if (!row.accepted)
                compare(incoming.Drag.drop(), Qt.IgnoreAction);
            incoming.Drag.active = false;
        }
        compare(fakeTab.hovered, ["file:///home/u"], "only Home sprang");
    }

    // The Applications place (kind "applications") is an ordinary place to the sidebar: a click opens its location in the tab
    // (a new tab and Back/Forward are the tab's, as for a folder); it has no eject menu.
    function test_applicationsPlaceOpensItsLocation() {
        const listView = findList(sidebar);
        verify(listView !== null);
        const item = listView.itemAtIndex(3);
        verify(item !== null);
        fakeTab.navigated = [];
        mouseClick(item, 20, item.height / 2);
        compare(fakeTab.navigated, ["grassfield-apps:/"]);
        mouseClick(item, 20, item.height / 2, Qt.RightButton);
        compare(tc.menus.length, 0, "no eject menu on a place that cannot be ejected");
    }

    // A standard folder whose disk does not answer is listed, dimmed (PlacesModel's "unavailable"; re-review of 24bdf58,
    // MINOR 4).
    function test_anUnavailablePlaceIsDimmed() {
        const listView = findList(sidebar);
        verify(listView !== null);
        compare(listView.itemAtIndex(0).opacity, 1);
        placesItem.setProperty(0, "unavailable", true);
        tryCompare(listView.itemAtIndex(0), "opacity", Tokens.materialDisabledOpacity);
        placesItem.setProperty(0, "unavailable", false);
        tryCompare(listView.itemAtIndex(0), "opacity", 1);
    }

    function findList(item: Item): var {
        const stack = [item];
        while (stack.length) {
            const it = stack.pop();
            if (it.itemAtIndex !== undefined && it.count !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }
}
