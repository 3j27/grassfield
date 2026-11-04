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
            property bool isApplications: false

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
            function uriList(urls: var): string {
                return urls.join("\r\n");
            }
        }
        // BrowserTab's drag bracket: dragStarted before the system drag, dragFinished from its end.
        property var dragEvents: []
        function dragStarted(): void {
            fakeTab.dragEvents = fakeTab.dragEvents.concat(["started"]);
        }
        function dragFinished(dropAction: int): void {
            fakeTab.dragEvents = fakeTab.dragEvents.concat(["finished"]);
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
        // Every drop the views pass on (a drag that ends without a drop passes none).
        property var drops: []
        function dropUrls(urls: var, destination: url, model: var): void {
            fakeTab.drops = fakeTab.drops.concat([String(destination)]);
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

    // A row of a column drags (the view had no drag source: items could not be moved or copied from it); the system drag is
    // bracketed by the tab's dragStarted and dragFinished (BrowserTab keeps the view that started it alive until then).
    function test_aDragFromAColumnIsBracketed() {
        tryVerify(() => rowNamed("note.txt") !== null, 2000, "the column is listed");
        fakeTab.dragEvents = [];
        const file = rowNamed("note.txt");
        const start = file.mapToItem(test, 40, file.height / 2);
        mousePress(test, start.x, start.y);
        for (let i = 1; i <= 6; i++)
            mouseMove(test, start.x + i * 8, start.y);
        mouseRelease(test, start.x + 48, start.y);
        tryVerify(() => fakeTab.dragEvents.length >= 1, 2000, "the drag started");
        compare(fakeTab.dragEvents[0], "started");
        // Offscreen, the platform drag ends at once (no drop).
        tryVerify(() => fakeTab.dragEvents.indexOf("finished") > 0, 2000, "and ended after it started");
        tryVerify(() => !columns.dragging, 2000, "the view is free again");
    }

    // The columns stay as they are while a drag from one of them runs (a spring-loaded folder would free the column the
    // drag came from under the platform's nested event loop); the location the drag ended at is shown after it.
    function test_theColumnsWaitForTheDragThatStartedInThem() {
        tryVerify(() => rowNamed("note.txt") !== null, 2000, "the column is listed");
        columns.dragging = true;
        fakeTab.segments = [{url: "file:///other"}];
        compare(String(columns.activeModel.url), "file:///sandbox", "no column is replaced during the drag");
        verify(columns.syncPending, "the change is kept");
        columns.dragging = false;
        columns.syncAfterDrag();
        compare(String(columns.activeModel.url), "file:///other", "the location is shown once the drag has ended");
        verify(!columns.syncPending);
        fakeTab.segments = [{url: "file:///sandbox"}];
    }

    // Nothing is dragged out of the Applications location (read-only).
    function test_nothingIsDraggedOutOfApplications() {
        tryVerify(() => rowNamed("note.txt") !== null, 2000, "the column is listed");
        const file = rowNamed("note.txt");
        fakeTab.dragEvents = [];
        columns.activeModel.isApplications = true;
        const start = file.mapToItem(test, 40, file.height / 2);
        mousePress(test, start.x, start.y);
        for (let i = 1; i <= 6; i++)
            mouseMove(test, start.x + i * 8, start.y);
        mouseRelease(test, start.x + 48, start.y);
        wait(100);
        compare(fakeTab.dragEvents, [], "no drag started");
        columns.activeModel.isApplications = false;
    }

    // A drag that ends without a drop moves nothing, however it ends: Escape (the platform ends the drag; offscreen it ends
    // at once, so no drop is delivered), a release outside every target, or over the dragged row itself (its own drop area
    // is off while it is selected). No drop reaches the tab.
    function dragNoteTxtBy(dx: real, dy: real): void {
        const file = rowNamed("note.txt");
        const start = file.mapToItem(test, 40, file.height / 2);
        mousePress(test, start.x, start.y);
        for (let i = 1; i <= 6; i++)
            mouseMove(test, start.x + i * 8, start.y);
        mouseMove(test, start.x + dx, start.y + dy);
        mouseRelease(test, start.x + dx, start.y + dy);
    }

    function test_aDragThatEndsWithoutADropPassesNoDrop() {
        tryVerify(() => rowNamed("note.txt") !== null, 2000, "the column is listed");
        fakeTab.drops = [];
        const ends = [[0, 300], [600, 0], [48, 0]];
        for (const e of ends) {
            fakeTab.dragEvents = [];
            dragNoteTxtBy(e[0], e[1]);
            tryVerify(() => fakeTab.dragEvents.indexOf("finished") > 0, 2000, "the drag ended");
            tryVerify(() => !columns.dragging, 2000, "the view is free again");
        }
        compare(fakeTab.drops, [], "no drop reached the tab");
    }

    // What a drag carries is the row pressed: a click on a row selects that row alone.
    function test_thePressedRowIsTheOnlySelection() {
        tryVerify(() => rowNamed("note.txt") !== null, 2000, "the column is listed");
        const file = rowNamed("note.txt");
        mouseClick(file, 40, file.height / 2, Qt.LeftButton);
        compare(columns.activeModel.selectedUrls().length, 1);
        compare(String(columns.activeModel.selectedUrls()[0]), "file:///sandbox/note.txt");
    }
}
