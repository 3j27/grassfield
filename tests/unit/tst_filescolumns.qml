pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// grassfield-files column view (apps/files/qml/ColumnView.qml) on a stand-in listing: a double-click opens a file, a
// folder only with Cmd (Ctrl here: a new tab, as in the other views), since a plain click already shows a folder in the
// next column (opus counter-review of PR #5: only Nav.columnDoubleClickOpens was tested, so the view could drop it).
TestCase {
    id: test
    name: "FilesColumns"
    when: windowShown
    // Shown: pointer events reach only visible items.
    visible: true
    width: 900
    height: 400

    // The FolderModel API a column uses, on a ListModel with the same roles.
    Component {
        id: listingComponent
        ListModel {
            id: listing

            property url url
            property int currentRow: -1
            property int selectedCount: 0
            property string title: "sandbox"
            property bool loading: false
            property string error: ""

            signal revealRequested(int row, bool rename)

            function expect(url: url, rename: bool): void {
            }
            function select(row: int, modifiers: int): void {
                listing.currentRow = row;
                for (let i = 0; i < listing.count; i++)
                    listing.setProperty(i, "selected", i === row);
                listing.selectedCount = row >= 0 ? 1 : 0;
            }
            function selectedRows(): var {
                return listing.currentRow >= 0 ? [listing.currentRow] : [];
            }
            function isDirAt(row: int): bool {
                return listing.get(row).isDir;
            }
            function urlAt(row: int): url {
                return listing.get(row).url;
            }
            function selectedUrls(): var {
                return listing.currentRow >= 0 ? [listing.get(listing.currentRow).url] : [];
            }
            function selectUrls(urls: var): void {
            }
            function isSelected(row: int): bool {
                return row === listing.currentRow;
            }
            function info(row: int): var {
                return row >= 0 ? {name: listing.get(row).name, isDir: listing.get(row).isDir, url: listing.get(row).url, kind: "", size: -1, tags: [], tagKeys: [], tagColors: []} : null;
            }
            // The preview requests, in order: "request <name> large" / "cancel <name> large".
            property var previews: []
            function requestPreview(row: int, large: bool): void {
                listing.previews = listing.previews.concat(["request " + listing.get(row).name + (large ? " large" : "")]);
            }
            function cancelPreview(url: url, large: bool): void {
                listing.previews = listing.previews.concat(["cancel " + String(url).split("/").pop() + (large ? " large" : "")]);
            }

            Component.onCompleted: {
                // photo.png first: a pane made with its row already 0 saw no change of it.
                const rows = [["photo.png", false], ["Folder", true], ["note.txt", false], ["\u05e9\u05dc\u05d5\u05dd.txt", false]];
                for (const r of rows) {
                    listing.append({name: r[0], url: "file:///sandbox/" + r[0], iconName: "", emblem: "", selected: false, isDir: r[1],
                                    folderColor: "", folderGlyph: "", hidden: false, dimmed: false, tagColors: []});
                }
            }
        }
    }

    // The BrowserTab API the column view uses; it records the activations.
    QtObject {
        id: fakeTab

        property var segments: [{url: "file:///sandbox"}]
        property var activated: []
        property var chooser: null
        property var app: QtObject {
            property bool columnPreview: false
            function rotatableImages(urls: var): var {
                return [];
            }
            function tagsUnavailable(urls: var): string {
                return "";
            }
            function baseNameLength(name: string, isDir: bool): int {
                return name.length;
            }
            function isRecents(url: url): bool {
                return false;
            }
        }
        function createModel(owner: var): var {
            return listingComponent.createObject(owner);
        }
        function applyPrefs(model: var): void {
        }
        function navigate(url: url, record: bool): void {
        }
        function activate(row: int, model: var, modifiers: int): void {
            fakeTab.activated = fakeTab.activated.concat([model.get(row).name + ((modifiers & Qt.ControlModifier) ? " +cmd" : "")]);
        }
        function contextMenu(model: var, row: int, x: real, y: real, keyboard: bool): void {
        }
        function dropUrls(urls: var, destination: url, model: var): void {
        }
        function springHover(url: url): void {
        }
        function springLeave(url: url): void {
        }
        function handleViewKey(event: var, model: var, mover: var): void {
        }
        function isRenaming(model: var, url: url): bool {
            return false;
        }
        function startRename(model: var, row: int): void {
        }
        function commitRename(name: string): void {
        }
        function cancelRename(): void {
        }
    }

    ColumnView {
        id: columns
        anchors.fill: parent
        tab: fakeTab
    }

    // The row delegate showing `name`.
    function rowNamed(name: string): var {
        const stack = [columns];
        while (stack.length) {
            const it = stack.pop();
            if (it.name === name && it.isDir !== undefined && it.renaming !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // A column replaced at the active place (a panel starting in its location after the tab's first one, a location of the
    // same depth): the active column is the new one, and its listing the active model, whose selection a panel reads
    // (integrator nested pass of f9a25ce, follow-up 1: the binding kept the destroyed column, so the panel read the tab's
    // own listing: Open stayed disabled after a click in the column).
    function test_aReplacedColumnIsTheActiveOne() {
        tryVerify(() => rowNamed("note.txt") !== null, 2000, "the column is listed");
        compare(columns.activeColumn, 0);
        verify(columns.activeModel !== null);
        compare(String(columns.activeModel.url), "file:///sandbox");
        fakeTab.segments = [{url: "file:///other"}];
        compare(columns.activeColumn, 0, "the same place");
        verify(columns.activeItem !== null, "the new column");
        verify(columns.activeModel !== null, "its listing");
        compare(String(columns.activeModel.url), "file:///other");
        const file = rowNamed("note.txt");
        mouseClick(file, 40, file.height / 2, Qt.LeftButton);
        compare(columns.activeModel.selectedCount, 1, "a click selects in the active listing");
        fakeTab.segments = [{url: "file:///sandbox"}];
    }

    // A name that starts with a right-to-left letter keeps to the left edge, as every name (integrator nested pass of step 5c,
    // NIT: Qt aligned it right by itself).
    function test_aRightToLeftNameStartsAtTheLeft() {
        tryVerify(() => rowNamed("\u05e9\u05dc\u05d5\u05dd.txt") !== null, 2000, "the column is listed");
        const row = rowNamed("\u05e9\u05dc\u05d5\u05dd.txt");
        const stack = [row];
        let label = null;
        while (stack.length && !label) {
            const it = stack.pop();
            if (it.effectiveHorizontalAlignment !== undefined && String(it.text).indexOf("\u05e9") >= 0)
                label = it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        verify(label !== null, "the name's label");
        compare(label.effectiveHorizontalAlignment, Text.AlignLeft);
    }

    function test_aDoubleClickOpensAFileAndAFolderOnlyWithCmd() {
        tryVerify(() => rowNamed("note.txt") !== null, 2000, "the column is listed");
        const file = rowNamed("note.txt");
        const folder = rowNamed("Folder");
        verify(folder !== null);
        fakeTab.activated = [];
        mouseDoubleClickSequence(file, 40, file.height / 2, Qt.LeftButton);
        compare(fakeTab.activated, ["note.txt"], "a file opens");
        mouseDoubleClickSequence(folder, 40, folder.height / 2, Qt.LeftButton);
        compare(fakeTab.activated, ["note.txt"], "a folder does not: a click already shows it in the next column");
        mouseDoubleClickSequence(folder, 40, folder.height / 2, Qt.LeftButton, Qt.ControlModifier);
        compare(fakeTab.activated, ["note.txt", "Folder +cmd"], "Cmd-double-click opens the folder (in a new tab)");
    }

    // The preview column asks for the selected file's large preview as soon as it is made (website captures of
    // 2026-10-30: the column only exists once a file is selected, so a first row, 0 from the start, never changed and the
    // picture showed the type icon), then for each file selected next, cancelling the previous request.
    function test_thePreviewColumnAsksForThePictureAtOnce() {
        tryVerify(() => rowNamed("photo.png") !== null, 2000, "the column is listed");
        fakeTab.app.columnPreview = true;
        const listing = columns.activeModel;
        listing.previews = [];
        const photo = rowNamed("photo.png");
        mouseClick(photo, 40, photo.height / 2, Qt.LeftButton);
        verify(columns.previewInfo !== null, "a selected file shows the preview column");
        tryVerify(() => listing.previews.indexOf("request photo.png large") >= 0, 2000, "the large preview is asked for: " + JSON.stringify(listing.previews));
        const note = rowNamed("note.txt");
        mouseClick(note, 40, note.height / 2, Qt.LeftButton);
        tryVerify(() => listing.previews.indexOf("request note.txt large") >= 0, 2000, "the next file's too: " + JSON.stringify(listing.previews));
        verify(listing.previews.indexOf("cancel photo.png large") >= 0, "and the previous request is cancelled: " + JSON.stringify(listing.previews));
        fakeTab.app.columnPreview = false;
        listing.select(-1, 0);
    }

    // The strip of columns.
    function strip(): var {
        const stack = [columns];
        while (stack.length) {
            const it = stack.pop();
            if (it.contentX !== undefined && it.contentWidth !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // In a view narrower than its columns, the preview column that a file selection opens is scrolled into view (Finder; the
    // nested pass of 2026-10-31 found it past the right edge: selecting a file keeps the location, so nothing scrolled).
    function test_thePreviewColumnIsScrolledIntoView() {
        tryVerify(() => rowNamed("photo.png") !== null, 2000, "the column is listed");
        const flick = strip();
        verify(flick !== null);
        const wide = columns.width;
        columns.anchors.fill = undefined;
        columns.width = 300;
        fakeTab.app.columnPreview = true;
        const photo = rowNamed("photo.png");
        mouseClick(photo, 40, photo.height / 2, Qt.LeftButton);
        verify(columns.previewInfo !== null);
        tryVerify(() => flick.contentWidth > flick.width, 2000, "the preview column widens the strip past the view");
        tryVerify(() => flick.contentX === flick.contentWidth - flick.width, 2000, "scrolled to its end: contentX " + flick.contentX + " of " + (flick.contentWidth - flick.width));
        fakeTab.app.columnPreview = false;
        columns.activeModel.select(-1, 0);
        columns.width = wide;
        columns.anchors.fill = test;
    }
}
