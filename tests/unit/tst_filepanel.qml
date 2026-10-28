pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"
import "../../apps/files/qml/PanelLogic.js" as PanelLogic

// grassfield-portal's Open and Save panels (apps/files/qml/FilePanel.qml; ADR-0035 D-4, docs/specs/system-dialogs.md section
// 1) offscreen, over a stand-in FilesApp, a stand-in FileChooser (the answers it gets) and a stand-in listing of a small
// tree: what each kind of panel answers, the replace questions, the refusal of a network location, the filters and choices,
// Esc, the panel's menus, and what it remembers. PanelLogic.js's rules first.
TestCase {
    id: test
    name: "FilePanel"
    when: windowShown

    // The tree the stand-in listing shows: folder URL -> [name, isDir].
    readonly property var tree: ({
            "file:///home/u": [["Documents", true], ["notes.txt", false]],
            "file:///home/u/Documents": [["a.txt", false], ["b.png", false], ["Sub", true]],
            "file:///home/u/Documents/Sub": [["x.txt", false]],
            "file:///home/u/My Documents": [["c.txt", false]],
            "smb://server/share": [["remote.txt", false]]
        })

    // The tree's entries for a folder URL in either form QML prints it (a typed url parameter prints "My%20Documents", a
    // url from Qt.url() "My Documents").
    function entries(folder: string): var {
        return test.tree[folder] || test.tree[decodeURI(folder)];
    }

    // FolderModel as the panel, BrowserTab and the icon view read it.
    Component {
        id: listingComponent
        ListModel {
            id: listing
            property url url
            property bool loading: false
            property string error: ""
            property real freeSpace: -1
            property bool isTrash: false
            property bool writable: true
            property bool isSearch: false
            property bool isRecents: false
            property bool searchLimited: false
            property string filterText: ""
            property int groupBy: 0
            property var groups: []
            property int sortKey: 0
            property bool sortDescending: false
            property bool foldersFirst: true
            property bool showHidden: false
            property int previewSize: 0
            property int largePreviewSize: 0
            property int currentRow: -1
            property int selectedCount: 0
            property var chooser: ({})
            property var expected: []
            property string title: ""
            signal redirected(url url)
            signal revealRequested(int row, bool rename)
            signal selectionChanged

            onUrlChanged: listing.relist()
            onChooserChanged: listing.relist()

            // FolderModel::dimmed: a file the panel cannot take (folders only; else a "*.ext" glob it does not match).
            function dimmedFor(name: string, isDir: bool): bool {
                const c = listing.chooser;
                if (!c || Object.keys(c).length === 0 || isDir)
                    return false;
                if (c.foldersOnly)
                    return true;
                const globs = c.globs || [];
                return globs.length > 0 && !globs.some(g => name.toLowerCase().endsWith(g.substring(1).toLowerCase()));
            }
            function relist(): void {
                const keep = listing.selectedUrls().map(String);
                listing.clear();
                const entries = test.entries(String(listing.url)) || [];
                for (const e of entries) {
                    const url = String(listing.url) + "/" + e[0];
                    listing.append({name: e[0], url: url, iconName: "", thumbnail: "", largeThumbnail: "", emblem: "", isDir: e[1], canPreview: false,
                                    hidden: false, dimmed: listing.dimmedFor(e[0], e[1]), tagColors: [], folderColor: "", folderGlyph: "",
                                    selected: keep.indexOf(url) >= 0 && !listing.dimmedFor(e[0], e[1]), modifiedText: "", sizeText: "", kind: "", group: ""});
                }
                listing.countSelected();
            }
            function countSelected(): void {
                let n = 0;
                for (let i = 0; i < listing.count; i++)
                    n += listing.get(i).selected ? 1 : 0;
                listing.selectedCount = n;
                listing.selectionChanged();
            }
            function select(row: int, modifiers: int): void {
                const single = listing.chooser.single === true;
                for (let i = 0; i < listing.count; i++) {
                    const on = i === row ? !listing.get(i).dimmed : (!single && (modifiers & Qt.ControlModifier) ? listing.get(i).selected : false);
                    listing.setProperty(i, "selected", on);
                }
                listing.currentRow = row;
                listing.countSelected();
            }
            function selectAll(): void {
            }
            function clearSelection(): void {
                listing.select(-1, 0);
            }
            function selectUrls(urls: var): void {
            }
            function selectedRows(): var {
                const rows = [];
                for (let i = 0; i < listing.count; i++) {
                    if (listing.get(i).selected)
                        rows.push(i);
                }
                return rows;
            }
            function selectedUrls(): var {
                return listing.selectedRows().map(r => listing.get(r).url);
            }
            function isSelected(row: int): bool {
                return row >= 0 && row < listing.count && listing.get(row).selected;
            }
            function findPrefix(prefix: string, from: int): int {
                return -1;
            }
            function rowForUrl(target: url): int {
                for (let i = 0; i < listing.count; i++) {
                    if (String(listing.get(i).url) === String(target))
                        return i;
                }
                return -1;
            }
            function isDirAt(row: int): bool {
                return row >= 0 && row < listing.count && listing.get(row).isDir;
            }
            function nameAt(row: int): string {
                return row >= 0 && row < listing.count ? listing.get(row).name : "";
            }
            function urlAt(row: int): url {
                return row >= 0 && row < listing.count ? listing.get(row).url : "";
            }
            function expect(target: url, rename: bool): void {
                listing.expected = listing.expected.concat([String(target)]);
            }
            function reload(): void {
            }
            function requestPreview(row: int, large: bool): void {
            }
            function cancelPreview(target: url, large: bool): void {
            }
            function info(row: int): var {
                return {name: "", url: listing.url, isDir: true, kind: "Folder", sizeText: "", where: "/", created: "", modified: "", accessed: ""};
            }
        }
    }

    ListModel {
        id: places
        property bool trashEmpty: true
        signal mounted(url url)
        function rowForUrl(target: url): int {
            return -1;
        }
        function eject(row: int): void {
        }
        function mount(row: int): void {
        }
    }

    // What the panel, BrowserTab, the sidebar and the views read of FilesApp.
    QtObject {
        id: fakeApp
        property bool dark: false
        property bool reduceMotion: false
        property string accentColor: "multicolor"
        property string accentHighlight: "automatic"
        property string shortcutStyle: "pc"
        property string iconMode: "default"
        property string iconTint: "accent"
        property string folderColor: "theme"
        property string viewMode: "icons"
        property int sortKey: 0
        property bool sortDescending: false
        property int recentsSortKey: 5
        property bool foldersFirst: true
        property bool showHidden: false
        property bool previewPane: false
        property bool galleryInfo: false
        property bool columnPreview: false
        property bool canPaste: false
        property int clipboardCount: 0
        property bool devSession: true
        property int tagRevision: 0
        property int folderStyleRevision: 0
        property var colorTagNames: []
        property var hiddenTags: []
        function tagName(tag: string): string {
            return tag;
        }
        property string homePath: "/home/u"
        property var places: places
        property var prompts: null
        property var folderViews: ({})
        property var made: []
        signal prefsChanged
        signal operationFailed(string message)
        function createFolderModel(owner: var): var {
            return listingComponent.createObject(owner);
        }
        function folderView(target: url): var {
            return fakeApp.folderViews[String(target)] || {};
        }
        function setFolderView(target: url, view: var): void {
            const all = Object.assign({}, fakeApp.folderViews);
            all[String(target)] = Object.assign({}, all[String(target)] || {}, view);
            fakeApp.folderViews = all;
        }
        function pathSegments(target: url): var {
            const s = String(target);
            if (s.startsWith("smb:"))
                return [{label: "share", url: target}];
            const parts = s.substring("file://".length).split("/").filter(p => p !== "");
            const out = [];
            let at = "file://";
            for (const p of parts) {
                at += "/" + p;
                out.push({label: p, url: at});
            }
            return out;
        }
        function sameUrl(a: url, b: url): bool {
            return String(a) === String(b);
        }
        function isRecents(target: url): bool {
            return false;
        }
        function defaultDescending(key: int): bool {
            return false;
        }
        function isDirectChild(parent: url, child: url): bool {
            return false;
        }
        function formatSize(bytes: real): string {
            return String(bytes);
        }
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function applicationsFor(urls: var): var {
            return [];
        }
        function baseNameLength(name: string, isDir: bool): int {
            const dot = name.lastIndexOf(".");
            return dot > 0 ? dot : name.length;
        }
        function isValidFileName(name: string): bool {
            return name !== "" && name !== "." && name !== ".." && name.indexOf("/") < 0;
        }
        function resolveLocation(text: string, base: url): url {
            return test.tree[text] ? text : "";
        }
        function uriList(urls: var): string {
            return "";
        }
        function rotatableImages(urls: var): var {
            return [];
        }
        function glance(urls: var): void {
        }
        function makeFolder(directory: url, name: string, done: var): void {
            fakeApp.made = fakeApp.made.concat([String(directory) + "/" + name]);
            done(String(directory) + "/" + name, "");
        }
    }

    // FileChooser (apps/portal/src/filechooser.h) as the panel uses it.
    QtObject {
        id: fakeHost
        property var answers: []
        property var remembered: []
        // URL -> 0 none, 1 file, 2 folder (pathKind); the tree's folders are folders.
        property var kinds: ({})
        function answer(id: int, response: int, map: var): void {
            fakeHost.answers = fakeHost.answers.concat([{id: id, response: response, map: map}]);
        }
        function remember(appId: string, entry: var): void {
            fakeHost.remembered = fakeHost.remembered.concat([{appId: appId, entry: entry}]);
        }
        function pathKind(target: url): int {
            const s = String(target);
            if (!s.startsWith("file:"))
                return -1;
            if (test.entries(s))
                return 2;
            return fakeHost.kinds[s] ?? 0;
        }
        function appName(appId: string): string {
            return "Example";
        }
    }

    // FilePanels.qml as a panel reads it.
    QtObject {
        id: fakeManager
        property string testAnswer: ""
        property var lastActiveWindow: null
        property var promptWindow: null
        function springStarted(tab: var): void {
        }
        function dragEnded(dropped: bool): void {
        }
    }

    Component {
        id: panelComponent
        FilePanel {
            app: fakeApp
            host: fakeHost
            manager: fakeManager
            requestId: 7
            places: ({home: "file:///home/u", desktop: "", documents: "file:///home/u/Documents", downloads: ""})
        }
    }

    function request(fields: var): var {
        return Object.assign({kind: "open", appId: "org.example.App", title: "", acceptLabel: "", modal: true, parented: false, multiple: false,
                              directory: false, filters: [], currentFilter: -1, choices: [], currentName: "", files: [], currentFolder: "",
                              currentFile: ""}, fields);
    }

    // A panel for `fields`, shown and active.
    function openPanel(fields: var, extra: var): var {
        fakeHost.answers = [];
        fakeHost.remembered = [];
        fakeHost.kinds = {};
        const panel = createTemporaryObject(panelComponent, test, Object.assign({request: test.request(fields)}, extra || {}));
        verify(panel !== null, "FilePanel");
        panel.show();
        panel.requestActivate();
        tryVerify(() => panel.active, 2000, "the panel is active");
        return panel;
    }

    function findTab(item: var): var {
        if (item instanceof BrowserTab)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const t = test.findTab(item.children[i]);
            if (t)
                return t;
        }
        return null;
    }

    function rowOf(model: var, name: string): int {
        for (let i = 0; i < model.count; i++) {
            if (model.get(i).name === name)
                return i;
        }
        return -1;
    }

    function cleanup(): void {
        fakeManager.testAnswer = "";
    }

    // PanelLogic.js --------------------------------------------------------------------------------------------------------

    function test_logic_filter_follows_the_request(): void {
        const filters = [{name: "Text", globs: ["*.txt"], mimeTypes: ["text/plain"]}, {name: "Images", globs: [], mimeTypes: ["image/*"]}];
        const f = PanelLogic.filterFor(test.request({filters: filters, currentFilter: 1}), 1);
        compare(f.globs, []);
        compare(f.mimeTypes, ["image/*"]);
        verify(!f.foldersOnly);
        verify(f.single);
        verify(PanelLogic.filterFor(test.request({directory: true}), -1).foldersOnly);
        verify(PanelLogic.filterFor(test.request({kind: "saveFiles"}), -1).foldersOnly);
        verify(!PanelLogic.filterFor(test.request({multiple: true}), -1).single);
        verify(PanelLogic.filterFor(test.request({kind: "save", multiple: true}), -1).single);
    }

    function test_logic_open_action(): void {
        const files = test.request({});
        compare(PanelLogic.openAction(files, [], "file:///d").action, "none");
        compare(PanelLogic.openAction(files, [{url: "file:///d/Sub", isDir: true}], "file:///d"), {action: "enter", url: "file:///d/Sub"});
        compare(PanelLogic.openAction(files, [{url: "file:///d/a", isDir: false}, {url: "file:///d/b", isDir: false}], "file:///d").uris, ["file:///d/a"]);
        compare(PanelLogic.openAction(test.request({multiple: true}), [{url: "file:///d/a", isDir: false}, {url: "file:///d/S", isDir: true}, {url: "file:///d/b", isDir: false}], "file:///d").uris,
                ["file:///d/a", "file:///d/b"]);
        const folders = test.request({directory: true});
        compare(PanelLogic.openAction(folders, [], "file:///d").uris, ["file:///d"]);
        compare(PanelLogic.openAction(folders, [{url: "file:///d/S", isDir: true}], "file:///d").uris, ["file:///d/S"]);
        verify(PanelLogic.openEnabled(folders, 0));
        verify(!PanelLogic.openEnabled(files, 0));
    }

    function test_logic_names_and_folders(): void {
        compare(PanelLogic.nameForFormat("Report.txt", ["*.md"]), "Report.md");
        compare(PanelLogic.nameForFormat("Report", ["*.md"]), "Report");
        compare(PanelLogic.nameForFormat("Report.txt", ["*.[mM][dD]"]), "Report.txt");
        compare(PanelLogic.nameForFormat(".bashrc", ["*.sh"]), ".bashrc");
        compare(PanelLogic.childUrl("file:///d/", "a b#?.txt"), "file:///d/a%20b%23%3F.txt");
        compare(PanelLogic.parentUrl("file:///d/e/f.txt"), "file:///d/e");
        compare(PanelLogic.parentUrl("file:///f.txt"), "file:///");
        verify(PanelLogic.isLocal("file:///d"));
        verify(!PanelLogic.isLocal("smb://host/d"));
        const isFolder = u => u === "file:///home/u" || u === "file:///home/u/Documents";
        const places = {home: "file:///home/u", documents: "file:///home/u/Documents"};
        compare(PanelLogic.startFolder(test.request({currentFolder: "file:///gone"}), {folder: "file:///home/u"}, places, isFolder), "file:///home/u");
        compare(PanelLogic.startFolder(test.request({}), {}, places, isFolder), "file:///home/u/Documents");
        compare(PanelLogic.startFolder(test.request({currentFolder: "file:///home/u"}), {folder: "file:///home/u/Documents"}, places, isFolder), "file:///home/u");
        compare(PanelLogic.choicesAnswer(test.request({choices: [{id: "a", initial: "x"}, {id: "b", initial: "false"}]}), {b: "true"}),
                [{id: "a", value: "x"}, {id: "b", value: "true"}]);
        compare(PanelLogic.clashes(["a", "b"], "file:///d", u => u.endsWith("/b") ? 1 : 0), [{name: "b", folder: false}]);
    }

    // The panel ------------------------------------------------------------------------------------------------------------

    function test_open_takes_a_file_the_filter_allows(): void {
        const panel = test.openPanel({title: "Open Report", currentFolder: "file:///home/u/Documents", currentFilter: 0,
                                      filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}, {name: "Images", globs: ["*.png"], mimeTypes: []}],
                                      choices: [{id: "ro", label: "Read only", options: [], initial: "true"}]});
        const tab = test.findTab(panel.contentItem);
        verify(tab !== null);
        compare(String(tab.url), "file:///home/u/Documents");
        compare(panel.acceptText, "Open");
        compare(panel.title, "Open Report");
        verify(!panel.acceptEnabled, "nothing selected: Open is disabled");
        compare(tab.folder.chooser.globs, ["*.txt"]);
        // The picture is dimmed and cannot be selected; the text file can.
        const m = tab.folder;
        verify(m.get(test.rowOf(m, "b.png")).dimmed);
        m.select(test.rowOf(m, "b.png"), 0);
        compare(m.selectedCount, 0);
        m.select(test.rowOf(m, "a.txt"), 0);
        verify(panel.acceptEnabled);
        panel.pressDefault();
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].response, 0);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt"]);
        compare(fakeHost.answers[0].map.choices, [{id: "ro", value: "true"}]);
        compare(fakeHost.answers[0].map.filter, 0);
        // What the application's panel is left with.
        compare(fakeHost.remembered[0].entry.folder, "file:///home/u/Documents");
        compare(fakeHost.remembered[0].entry.view, "icons");
        // Answered once.
        panel.pressDefault();
        compare(fakeHost.answers.length, 1);
    }

    function test_the_format_changes_what_is_dimmed(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents", currentFilter: 0,
                                      filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}, {name: "Images", globs: ["*.png"], mimeTypes: []}]});
        const tab = test.findTab(panel.contentItem);
        panel.filterIndex = 1;
        compare(tab.folder.chooser.globs, ["*.png"]);
        verify(tab.folder.get(test.rowOf(tab.folder, "a.txt")).dimmed);
        verify(!tab.folder.get(test.rowOf(tab.folder, "b.png")).dimmed);
    }

    function test_a_folder_selected_in_a_file_panel_opens(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "Sub"), 0);
        panel.pressDefault();
        compare(String(tab.url), "file:///home/u/Documents/Sub");
        compare(fakeHost.answers.length, 0);
    }

    function test_a_folder_panel_chooses_the_shown_or_selected_folder(): void {
        let panel = test.openPanel({directory: true, acceptLabel: "_Choose", currentFolder: "file:///home/u/Documents"});
        let tab = test.findTab(panel.contentItem);
        verify(tab.folder.get(test.rowOf(tab.folder, "a.txt")).dimmed, "files are dimmed");
        verify(panel.acceptEnabled);
        panel.pressDefault();
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents"]);
        panel.destroy();
        panel = test.openPanel({directory: true, currentFolder: "file:///home/u/Documents"});
        tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "Sub"), 0);
        panel.pressDefault();
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/Sub"]);
    }

    function test_a_double_click_on_a_file_chooses_it(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents", filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}], currentFilter: 0});
        const tab = test.findTab(panel.contentItem);
        tab.activate(test.rowOf(tab.folder, "b.png"), tab.folder, 0);
        compare(fakeHost.answers.length, 0, "a dimmed file is not chosen");
        tab.activate(test.rowOf(tab.folder, "Sub"), tab.folder, 0);
        compare(String(tab.url), "file:///home/u/Documents/Sub", "a folder opens");
        tab.activate(test.rowOf(tab.folder, "x.txt"), tab.folder, 0);
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/Sub/x.txt"]);
    }

    function test_return_in_the_listing_is_the_default_button(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "a.txt"), 0);
        tab.focusView();
        tryVerify(() => tab.view && tab.view.activeFocus !== undefined);
        keyClick(Qt.Key_Return);
        tryCompare(fakeHost.answers, "length", 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt"]);
    }

    function test_escape_cancels(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents", currentName: ""});
        keyClick(Qt.Key_Escape);
        tryCompare(fakeHost.answers, "length", 1);
        compare(fakeHost.answers[0].response, 1);
        compare(fakeHost.remembered.length, 1, "a cancel keeps the folder too");
    }

    function test_a_network_location_is_refused(): void {
        const panel = test.openPanel({directory: true, currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.navigate("smb://server/share", true);
        panel.pressDefault();
        compare(fakeHost.answers.length, 0);
        verify(panel.sheetShown, "the refusal is a sheet");
        keyClick(Qt.Key_Return);
        tryVerify(() => !panel.sheetShown);
        compare(fakeHost.answers.length, 0);
    }

    function test_save_compact_saves_the_name_in_the_shown_folder(): void {
        const panel = test.openPanel({kind: "save", currentName: "Report.txt", currentFolder: "file:///home/u/Documents", currentFilter: 0,
                                      filters: [{name: "Text", globs: ["*.txt"], mimeTypes: []}, {name: "Markdown", globs: ["*.md"], mimeTypes: []}]});
        verify(!panel.expanded, "compact by default");
        verify(panel.height < Tokens.filesPanelHeight);
        compare(panel.acceptText, "Save");
        // The Format pop-up changes the extension.
        const tab = test.findTab(panel.contentItem);
        panel.filterIndex = 1;
        // The name field is the one TextField of the header.
        let name = null;
        const walk = item => {
            if (item instanceof TextField && !name)
                name = item;
            for (let i = 0; i < item.children.length; i++)
                walk(item.children[i]);
        };
        walk(panel.contentItem);
        verify(name !== null);
        compare(name.text, "Report.txt");
        name.text = PanelLogic.nameForFormat(name.text, ["*.md"]);
        panel.pressDefault();
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/Report.md"]);
        compare(fakeHost.answers[0].map.filter, 1);
        compare(fakeHost.remembered[0].entry.expanded, false);
        verify(String(tab.url) === "file:///home/u/Documents");
    }

    function test_save_expands_and_remembers(): void {
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents"}, {memory: {expanded: true, view: "list"}});
        verify(panel.expanded);
        const tab = test.findTab(panel.contentItem);
        compare(tab.viewMode, "list");
        tab.setViewMode("columns");
        panel.expanded = false;
        panel.cancel();
        compare(fakeHost.remembered[0].entry.view, "columns");
        compare(fakeHost.remembered[0].entry.expanded, false);
    }

    function test_save_over_a_file_asks_first(): void {
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents"});
        fakeHost.kinds = {"file:///home/u/Documents/a.txt": 1};
        panel.pressDefault();
        verify(panel.sheetShown, "the replace question");
        compare(fakeHost.answers.length, 0);
        // Return is Cancel (macOS: Replace is never the default here).
        keyClick(Qt.Key_Return);
        tryVerify(() => !panel.sheetShown);
        compare(fakeHost.answers.length, 0);
        panel.pressDefault();
        verify(panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        verify(sheet !== null);
        sheet.confirm();
        tryCompare(fakeHost.answers, "length", 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt"]);
    }

    function test_save_with_a_folders_name_is_refused(): void {
        const panel = test.openPanel({kind: "save", currentName: "Sub", currentFolder: "file:///home/u/Documents"});
        panel.pressDefault();
        verify(panel.sheetShown);
        compare(fakeHost.answers.length, 0);
    }

    function test_save_files_asks_about_the_names_that_exist(): void {
        const panel = test.openPanel({kind: "saveFiles", files: ["a.txt", "c.txt"], currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        verify(tab.folder.get(test.rowOf(tab.folder, "a.txt")).dimmed, "a folder panel");
        fakeHost.kinds = {"file:///home/u/Documents/a.txt": 1};
        panel.pressDefault();
        verify(panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        verify(sheet.title.indexOf("a.txt") >= 0);
        sheet.confirm();
        tryCompare(fakeHost.answers, "length", 1);
        compare(fakeHost.answers[0].map.uris, ["file:///home/u/Documents/a.txt", "file:///home/u/Documents/c.txt"]);
    }

    function test_the_panels_menus_change_no_file(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.folder.select(test.rowOf(tab.folder, "a.txt"), 0);
        const ids = tab.actionMenu().map(i => i.id).filter(i => i !== undefined);
        for (const forbidden of ["trash", "rename", "copy", "cut", "paste", "duplicate", "info", "openWith", "newTab", "customize"])
            verify(ids.indexOf(forbidden) < 0, forbidden);
        verify(ids.indexOf("glance") >= 0);
        verify(tab.chooserMenu(tab.folder, false).every(i => i.id !== "newFolder"), "no New Folder in a file Open panel");
        verify(!tab.canRename());
        tab.startRename(tab.folder, 0);
        verify(tab.renameModel === null);
    }

    function test_new_folder_in_a_save_panel(): void {
        const panel = test.openPanel({kind: "save", currentName: "a.txt", currentFolder: "file:///home/u/Documents"}, {memory: {expanded: true}});
        const tab = test.findTab(panel.contentItem);
        verify(tab.chooserMenu(tab.folder, false).some(i => i.id === "newFolder"));
        fakeApp.made = [];
        panel.newFolder();
        verify(panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        sheet.confirm();
        compare(fakeApp.made, ["file:///home/u/Documents/untitled folder"]);
    }

    // A folder with a space (review of step 4b, BLOCKER 1 and NIT 15): Where lists it once, though the places come encoded and
    // with a trailing "/", and Save answers the name in it (the backend reads the URL as QML prints it).
    function test_where_lists_a_folder_with_a_space_once(): void {
        const panel = test.openPanel({kind: "save", currentName: "new file.txt", currentFolder: "file:///home/u/My Documents"},
                                     {places: {home: "file:///home/u/", desktop: "", documents: "file:///home/u/My%20Documents/", downloads: ""}});
        let where = null;
        const walk = item => {
            if (item instanceof ComboBox && item.accessibleName === "Where" && !where)
                where = item;
            for (let i = 0; i < item.children.length; i++)
                walk(item.children[i]);
        };
        walk(panel.contentItem);
        verify(where !== null, "the Where pop-up");
        const ids = [];
        for (let i = 0; i < where.model.length; i++)
            ids.push(where.model[i].id);
        compare(ids.filter(i => i === "file:///home/u/My Documents").length, 1, ids.join(", "));
        compare(ids.filter(i => i === "file:///home/u").length, 1, ids.join(", "));
        compare(where.value, "file:///home/u/My Documents");
        // A root keeps its "/" (counter-review of step 4b, NIT-1): "sftp://host" is no folder.
        compare(where.key("file:///home/u/"), "file:///home/u");
        compare(where.key("file:///"), "file:///");
        compare(where.key("sftp://host/"), "sftp://host/");
        compare(where.key("sftp://host/srv/"), "sftp://host/srv");
        compare(where.key("network:/"), "network:/");
        panel.pressDefault();
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].map.uris.length, 1);
        compare(decodeURIComponent(fakeHost.answers[0].map.uris[0]), "file:///home/u/My Documents/new file.txt");
    }

    // The panel is a dialog named by its title (spec common rule 4; review of step 4b, MINOR 9), and its sidebar changes no
    // tag: the Tags menu does not open, where Files would offer Show Hidden Tag (MINOR 4).
    function test_the_panel_is_an_accessible_dialog_and_its_sidebar_changes_no_tag(): void {
        const panel = test.openPanel({title: "Import a Picture", currentFolder: "file:///home/u/Documents"});
        let dialog = null;
        let sidebar = null;
        const walk = item => {
            if (!dialog && item.Accessible.role === Accessible.Dialog)
                dialog = item;
            if (!sidebar && item instanceof Sidebar)
                sidebar = item;
            for (let i = 0; i < item.children.length; i++)
                walk(item.children[i]);
        };
        walk(panel.contentItem);
        verify(dialog !== null, "an item with the Dialog role");
        compare(dialog.Accessible.name, "Import a Picture");
        verify(sidebar !== null, "the sidebar");
        verify(sidebar.choosing);
        fakeApp.hiddenTags = ["red"];
        sidebar.openTagMenu("", 10, 10);
        verify(!panel.menuLayer.visible, "no Tags menu in a panel");
        fakeApp.hiddenTags = [];
    }

    function test_a_drop_shows_the_item_and_moves_nothing(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u"});
        const tab = test.findTab(panel.contentItem);
        tab.dropUrls(["file:///home/u/Documents/Sub/x.txt"], "file:///home/u", tab.folder);
        compare(String(tab.url), "file:///home/u/Documents/Sub");
        compare(tab.folder.expected, ["file:///home/u/Documents/Sub/x.txt"]);
    }

    function test_slash_in_the_listing_opens_go_to_folder(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"});
        const tab = test.findTab(panel.contentItem);
        tab.focusView();
        tryVerify(() => tab.view !== null);
        wait(50);
        keyClick("/");
        tryVerify(() => panel.sheetShown);
        const sheet = test.findSheet(panel.contentItem, true);
        compare(sheet.fieldText, "/");
    }

    function test_a_panel_that_gets_the_keyboard_late_waits_for_a_click(): void {
        const panel = test.openPanel({currentFolder: "file:///home/u/Documents"}, {shownAt: 1});
        verify(panel.keysHeld);
        keyClick(Qt.Key_Escape);
        wait(50);
        compare(fakeHost.answers.length, 0, "a key does not answer it");
        mousePress(panel.contentItem, 10, 10);
        mouseRelease(panel.contentItem, 10, 10);
        verify(!panel.keysHeld);
    }

    // The shown Sheet under `item` (Sheet.shown), or null.
    function findSheet(item: var, shown: bool): var {
        if (item instanceof Sheet && (!shown || item.shown))
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const s = test.findSheet(item.children[i], shown);
            if (s)
                return s;
        }
        return null;
    }
}
