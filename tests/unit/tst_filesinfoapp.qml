pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// Get Info of an application and of the Applications location (apps/files/qml/InfoWindow.qml, FolderModel::info): the maps
// carry no file thumbnail, and the window must still bind every field without a QML warning ("Unable to assign [undefined] to
// QString", gate Q2: scripts/dev/test.sh runs tests/ci/qml_warnings.py over this run's output, which fails the run on one).
TestCase {
    id: test
    name: "FilesInfoApplication"
    when: windowShown
    width: 300
    height: 200

    // The FilesApp API the window uses.
    QtObject {
        id: fakeApp
        property var colorTagNames: ({})
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
        property int tagRevision: 0
        property int folderStyleRevision: 0
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function colorTagStates(urls: var): var {
            return [];
        }
        function tagNamesOf(url: url): var {
            return [];
        }
        function folderStyleOf(url: url): var {
            return {color: "", glyph: ""};
        }
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function applicationsCount(): int {
            return 63;
        }
        // Get Info's Sharing & Permissions (ADR-0028): nothing to edit here.
        signal permissionsChanged(url url)
        property var permissionsResult: ({valid: false})
        function permissionsOf(target: url): var {
            return fakeApp.permissionsResult;
        }
        function setGroup(target: url, group: string): void {
        }
        function setAccess(target: url, who: int, access: int): void {
        }
        property var jobs: []
        function applicationsFor(urls: var): var {
            return [];
        }
        function mimeTypeOf(target: url): string {
            return "text/plain";
        }
        function defaultApplication(mimeType: string): string {
            return "";
        }
        function setDefaultApplication(mimeType: string, storageId: string): bool {
            return true;
        }
        function directorySize(url: url, done: var): void {
        }
        function formatSize(bytes: real): string {
            return "";
        }
    }

    // What FolderModel::info returns for an application: no `thumbnail` key at all in the oldest build; the key is "" now.
    readonly property var appInfo: ({
        name: "Calculator",
        url: "grassfield-app:/org.gnome.Calculator",
        iconName: "application-x-executable",
        kind: "Application",
        isApplication: true,
        genericName: "Calculator",
        comment: "Perform arithmetic",
        where: "/usr/share/applications",
        desktopEntry: "/usr/share/applications/org.gnome.Calculator.desktop",
        command: "gnome-calculator",
        categories: "Utility",
        readable: true,
        writable: false,
        isDir: false,
        size: -1
    })
    readonly property var locationInfo: ({
        name: "Applications",
        url: "grassfield-apps:/",
        iconName: "folder",
        kind: "Applications",
        isDir: true,
        readable: true,
        writable: false
    })

    Component {
        id: windowComponent

        InfoWindow {
            app: fakeApp
            info: test.appInfo
        }
    }

    Component {
        id: locationComponent

        InfoWindow {
            app: fakeApp
            info: test.locationInfo
        }
    }

    Component {
        id: fileComponent

        InfoWindow {
            app: fakeApp
            info: ({name: "report.txt", url: "file:///tmp/report.txt", iconName: "text-plain", kind: "Plain Text", isDir: false,
                    readable: true, writable: true, size: 10, sizeText: "10 bytes", bytes: 10, where: "/tmp", created: "", modified: "",
                    accessed: "", linkDest: "", owner: "", group: "", permissions: "", thumbnail: ""})
        }
    }

    function items(item: var, name: string, out: var): var {
        if (item.objectName === name)
            out.push(item);
        for (let i = 0; i < item.children.length; i++)
            test.items(item.children[i], name, out);
        return out;
    }

    // Sharing & Permissions is a table (Finder): the Name column and the Privilege column never overlap, whatever the user and
    // group names, and a long name elides (review of PR #98: the group pop-up ran under the privilege pop-up, 34 px).
    function test_permissionsNameColumnNeverRunsUnderThePrivilegeColumn() {
        const longName = "a-user-with-a-really-quite-long-account-name";
        fakeApp.permissionsResult = {valid: true, mode: 420, modeText: "-rw-r--r--", owner: longName, group: "a-group-with-a-long-name-too",
                               ownedByMe: true, isDir: true, editable: true, reason: "",
                               groups: ["a-group-with-a-long-name-too", "another-quite-long-group-name", "wheel"], access: [3, 1, 1]};
        const win = createTemporaryObject(fileComponent, test);
        verify(win);
        win.show();
        tryVerify(() => win.visible && win.contentItem.width > 0, 3000);
        verify(win.permissionsShown);
        const privileges = test.items(win.contentItem, "privilege", []);
        compare(privileges.length, 3, "one privilege pop-up per row");
        const names = test.items(win.contentItem, "nameText", []).concat(test.items(win.contentItem, "groupChoice", [])).filter(i => i.visible);
        compare(names.length, 3, "one name control per row (a text, or the group's pop-up)");
        for (const n of names) {
            const row = n.parent;
            const privilege = privileges.find(p => p.parent === row);
            verify(privilege !== undefined);
            verify(n.x >= 0, "the name starts inside the row");
            verify(n.x + n.width <= privilege.x, "the name ends before the privilege begins (" + n.objectName + ": " + (n.x + n.width) + " > " + privilege.x + ")");
            verify(privilege.x + privilege.width <= row.width + 0.5, "the privilege stays inside the row");
        }
        fakeApp.permissionsResult = {valid: false};
    }

    function test_applicationInfoHasNoUndefinedThumbnail() {
        const win = createTemporaryObject(windowComponent, test);
        verify(win);
        compare(win.isApplication, true);
        // A warning here would be printed by Qt and caught by the Q2 gate; the info has no thumbnail and none is assigned.
        compare(win.info.thumbnail, undefined);
    }

    function test_applicationsLocationInfoHasNoUndefinedThumbnail() {
        const win = createTemporaryObject(locationComponent, test);
        verify(win);
        compare(win.isApplication, false);
    }
}
