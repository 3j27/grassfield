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
        function permissionsOf(target: url): var {
            return {valid: false};
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
