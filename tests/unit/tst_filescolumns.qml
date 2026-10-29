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
                return {name: listing.get(row).name, isDir: listing.get(row).isDir};
            }
            function requestPreview(row: int, large: bool): void {
            }
            function cancelPreview(url: url, large: bool): void {
            }

            Component.onCompleted: {
                const rows = [["Folder", true], ["note.txt", false]];
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
        property var app: QtObject {
            property bool columnPreview: false
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
}
