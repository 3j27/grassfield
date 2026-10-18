import QtQuick
import QtTest
import "../../apps/files/qml"

// grassfield-files gallery view (apps/files/qml/GalleryView.qml) on a stand-in listing: the first item is shown once
// the folder is listed, the arrow keys move along the strip (Nav.stripMove), the large preview follows the current
// item, Space and Return reach the tab, and the info panel follows its preference.
TestCase {
    id: test
    name: "FilesGallery"
    when: windowShown
    width: 900
    height: 520

    // The FolderModel API the gallery uses, on a ListModel with the same roles.
    ListModel {
        id: listing

        property int currentRow: -1
        property bool loading: false
        property string error: ""
        property url url: "file:///sandbox"
        property var largeRequests: []

        signal revealRequested(int row, bool rename)

        function select(row: int, modifiers: int): void {
            listing.currentRow = row;
            for (let i = 0; i < listing.count; i++)
                listing.setProperty(i, "selected", i === row);
        }
        function info(row: int): var {
            return {name: listing.get(row).name, kind: "Plain text document", sizeText: "1 KB", isDir: false, created: "Today at 10:00", modified: "Today at 11:00", accessed: "", where: "/sandbox"};
        }
        function requestPreview(row: int, large: bool): void {
            if (large)
                listing.largeRequests = listing.largeRequests.concat([row]);
        }
        function cancelPreview(url: url, large: bool): void {
        }
        function selectedUrls(): var {
            return listing.currentRow >= 0 ? [listing.get(listing.currentRow).url] : [];
        }

        // Dynamic roles keep tagColors a plain list (as FolderModel's role), not a nested ListModel.
        dynamicRoles: true

        function row(name: string, isDir: bool, canPreview: bool, tagColors: var): var {
            return {name: name, url: "file:///sandbox/" + name, iconName: "", thumbnail: "", largeThumbnail: "", emblem: "", selected: false, isDir: isDir,
                    canPreview: canPreview, hidden: false, tagColors: tagColors};
        }

        Component.onCompleted: {
            listing.append(listing.row("alpha.png", false, true, [0, 4]));
            listing.append(listing.row("beta.txt", false, false, []));
            listing.append(listing.row("gamma", true, false, [6]));
            listing.append(listing.row("delta.pdf", false, true, []));
            listing.append(listing.row("epsilon.md", false, false, [1, 2, 3, 5]));
        }
    }

    // The BrowserTab API the gallery uses. handleViewKey keeps BrowserTab's mapping for the keys tested here.
    QtObject {
        id: tab

        property string searchText: ""
        property int activated: -1
        property int glances: 0
        property var app: QtObject {
            property bool galleryInfo: true

            function baseNameLength(name: string, isDir: bool): int {
                return name.length;
            }
            function uriList(urls: var): string {
                return "";
            }
        }

        function isRenaming(model: var, url: url): bool {
            return false;
        }
        function startRename(model: var, row: int): void {
        }
        function activate(row: int, model: var): void {
            tab.activated = row;
        }
        function contextMenu(model: var, row: int, x: real, y: real, keyboard: bool): void {
        }
        function dropUrls(urls: var, destination: url, model: var): void {
        }
        function handleViewKey(event: var, model: var, mover: var): void {
            const names = {};
            names[Qt.Key_Left] = "left";
            names[Qt.Key_Right] = "right";
            names[Qt.Key_Up] = "up";
            names[Qt.Key_Down] = "down";
            names[Qt.Key_Home] = "home";
            names[Qt.Key_End] = "end";
            const name = names[event.key];
            if (name !== undefined) {
                const next = mover(name);
                if (next >= 0)
                    model.select(next, 0);
                event.accepted = true;
            } else if (event.key === Qt.Key_Space) {
                tab.glances++;
                event.accepted = true;
            } else if (event.key === Qt.Key_Return) {
                tab.activate(model.currentRow, model);
                event.accepted = true;
            }
        }
    }

    GalleryView {
        id: gallery
        anchors.fill: parent
        tab: tab
        model: listing
    }

    function init(): void {
        tab.app.galleryInfo = true;
        listing.select(0, 0);
        gallery.focusView();
        waitForRendering(gallery);
    }

    function test_showsTheFirstItemOnceListed() {
        // ensureCurrent ran when the view was created: the first item is current and the strip has the focus.
        verify(listing.currentRow >= 0);
        listing.currentRow = -1;
        gallery.ensureCurrent();
        compare(listing.currentRow, 0);
    }

    function test_arrowsMoveAlongTheStrip() {
        keyClick(Qt.Key_Right);
        compare(listing.currentRow, 1);
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Right);
        compare(listing.currentRow, 3);
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Down);
        compare(listing.currentRow, 3, "Up/Down do not move in the strip");
        keyClick(Qt.Key_End);
        compare(listing.currentRow, 4);
        keyClick(Qt.Key_Right);
        compare(listing.currentRow, 4, "the last item stays current");
        keyClick(Qt.Key_Left);
        compare(listing.currentRow, 3);
        keyClick(Qt.Key_Home);
        compare(listing.currentRow, 0);
        keyClick(Qt.Key_Left);
        compare(listing.currentRow, 0);
    }

    function test_spaceAndReturnReachTheTab() {
        const before = tab.glances;
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Space);
        compare(tab.glances, before + 1);
        keyClick(Qt.Key_Return);
        compare(tab.activated, 1);
    }

    function test_largePreviewFollowsTheCurrentItem() {
        listing.largeRequests = [];
        keyClick(Qt.Key_End);
        waitForRendering(gallery);
        // The page of delta.pdf (row 3, previewable) asked for its gallery-size thumbnail on its way into view.
        tryVerify(() => listing.largeRequests.indexOf(3) >= 0);
        compare(gallery.info.name, "epsilon.md");
    }

    function test_infoPanelFollowsItsPreference() {
        compare(gallery.info.name, "alpha.png");
        verify(gallery.showInfo);
        tab.app.galleryInfo = false;
        verify(!gallery.showInfo);
        tab.app.galleryInfo = true;
        verify(gallery.showInfo);
    }
}
