pragma ComponentBehavior: Bound
import QtQuick
import QtTest
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
        id: places

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
        }

        function rowForUrl(url): int {
            for (let i = 0; i < places.count; i++) {
                if (String(places.get(i).url) === String(url))
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

        property var places: places
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
        function navigate(url, record): void {
        }
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
