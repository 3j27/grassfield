pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// grassfield-files grouped icon view (apps/files/qml/IconView.qml, View > Group By) on a stand-in listing: only the
// sections near the view are made (their header, the DelegateModel of their rows, their views: a folder grouped by name
// can have thousands of groups, each DelegateModel follows every change of the listing), a view made before it has its
// size makes the cells of the lines it shows only, and a far group is made when it is scrolled to.
TestCase {
    id: test
    name: "FilesGrouped"
    when: windowShown
    visible: true
    width: 1000
    height: 700

    // The FolderModel API the icon view uses, on a ListModel with the same roles; `made` counts the cells (each asks for
    // its thumbnail when it is made).
    ListModel {
        id: listing

        property int groupBy: 1
        property var groups: []
        property int currentRow: -1
        property int selectedCount: 0
        property bool loading: false
        property string error: ""
        property url url: "file:///sandbox"
        property int made: 0
        property var asked: ({})

        signal revealRequested(int row, bool rename)

        function requestPreview(row: int, large: bool): void {
            listing.made++;
            listing.asked[row] = true;
        }
        function cancelPreview(url: url, large: bool): void {
        }
        function select(row: int, modifiers: int): void {
        }
        function selectedUrls(): var {
            return [];
        }
        function selectUrls(urls: var): void {
        }
        function clearSelection(): void {
        }
        function urlAt(row: int): url {
            return listing.get(row).url;
        }
        function isSelected(row: int): bool {
            return false;
        }
    }

    QtObject {
        id: fakeTab

        property string searchText: ""
        property var win: null
        property var app: QtObject {
            function baseNameLength(name: string, isDir: bool): int {
                return name.length;
            }
            function isRecents(url: url): bool {
                return false;
            }
            function uriList(urls: var): string {
                return "";
            }
        }
        function isRenaming(model: var, url: url): bool {
            return false;
        }
        function handleViewKey(event: var, model: var, mover: var): void {
        }
        function contextMenu(model: var, row: int, x: real, y: real, keyboard: bool): void {
        }
        function activate(row: int, model: var, modifiers: int): void {
        }
        function springHover(url: url): void {
        }
        function springLeave(url: url): void {
        }
        function dropUrls(urls: var, destination: url, model: var): void {
        }
        function dragStarted(): void {
        }
        function dragFinished(action: int): void {
        }
        function startRename(model: var, row: int): void {
        }
        function commitRename(name: string): void {
        }
        function cancelRename(): void {
        }
    }

    Component {
        id: viewComponent
        IconView {
            anchors.fill: parent
            tab: fakeTab
            model: listing
        }
    }

    // `groupCount` groups of `size` items, one first letter each (U+4E00 on: each its own Name group, FileLogic::groupOf).
    function fill(groupCount: int, size: int): void {
        listing.clear();
        listing.made = 0;
        listing.asked = {};
        const groups = [];
        for (let g = 0; g < groupCount; g++) {
            const letter = String.fromCharCode(0x4E00 + g);
            groups.push({title: letter, first: listing.count, count: size});
            for (let i = 0; i < size; i++) {
                listing.append({name: letter + " " + i, url: "file:///sandbox/" + g + "-" + i, iconName: "", thumbnail: "", emblem: "", selected: false,
                                isDir: false, folderColor: "", folderGlyph: "", canPreview: true, hidden: false, tagColors: []});
            }
        }
        listing.groups = groups;
    }

    function findText(item: Item, text: string): var {
        const stack = [item];
        while (stack.length) {
            const it = stack.pop();
            if (it.text === text && it.visible !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // Made before it has a size (as by the tab's view Loader), a view of 27 long groups makes the cells it shows, not every
    // cell of the groups near its top (before: 1,908 of 5,000 cells, every line laid out at a zero cell width).
    function test_aViewMadeBeforeItsSizeMakesWhatItShows() {
        fill(27, 185);
        const view = createTemporaryObject(viewComponent, test);
        verify(view !== null);
        waitForRendering(view);
        verify(listing.made > 0, "cells were made");
        verify(listing.made < 400, "cells made: " + listing.made);
    }

    // Of 600 groups only the ones near the view are made: a far group's header does not exist until it is scrolled to,
    // then its cells are made.
    function test_onlyTheSectionsNearTheViewAreMade() {
        fill(600, 3);
        const view = createTemporaryObject(viewComponent, test);
        verify(view !== null);
        waitForRendering(view);
        const last = String.fromCharCode(0x4E00 + 599);
        verify(findText(view, String.fromCharCode(0x4E00)) !== null, "the first group's header");
        compare(findText(view, last), null, "the last group is not made");
        verify(listing.made < 100, "cells made: " + listing.made);
        const flick = view.flick;
        flick.contentY = flick.contentHeight - flick.height;
        waitForRendering(view);
        tryVerify(() => findText(view, last) !== null, 2000, "the last group's header once scrolled to");
        tryVerify(() => listing.asked[listing.count - 1] === true, 2000, "and its cells");
        compare(findText(view, String.fromCharCode(0x4E00)), null, "the first group is gone");
    }

    // Show All lays a made group out in full; the keyboard's reveal reaches a group that was not made.
    function test_showAllAndRevealStillWork() {
        fill(40, 30);
        const view = createTemporaryObject(viewComponent, test);
        verify(view !== null);
        waitForRendering(view);
        const first = String.fromCharCode(0x4E00);
        view.setExpanded(first, true);
        waitForRendering(view);
        verify(findText(view, "Show Less") !== null, "the first group in full");
        tryVerify(() => listing.asked[29] === true, 2000, "its last item made");
        view.setExpanded(first, false);
        // The last item of the last group: the page goes down and the line along.
        view.reveal(listing.count - 1);
        waitForRendering(view);
        tryVerify(() => listing.asked[listing.count - 1] === true, 2000, "the revealed item is made");
    }
}
