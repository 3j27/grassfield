import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"

// The folder is listed after the window is up: the viewer starts with the opened file alone (no arrows, no "n of N")
// and follows the list when it arrives, staying on the opened file.
TestCase {
    id: testCase
    name: "PreviewListing"
    when: viewer.visible

    QtObject {
        id: backend
        property var files: [{name: "b.png", path: "/x/b.png", url: "file:///x/b.png", kind: "image"}]
        property var errors: []
        property bool glance: false
        property bool browsing: true
        property bool listing: true
        property int startIndex: 0
        property bool dark: true
        property bool reduceMotion: true
        property string titlebarDoubleClick: "zoom"
        function inspect(i) {
            return {ok: true, kind: "image", name: files[i].name, url: files[i].url, width: 1200, height: 800, frames: 1, animated: false, size: "1 MB", type: "PNG image", modified: "today", folder: "/x"};
        }
    }

    Viewer {
        id: viewer
        backend: backend
        globalMenu: false
    }

    function test_listArrivesLater() {
        compare(viewer.title, "b.png");
        compare(viewer.fileCount, 1);
        compare(viewer.subtitle, "");
        compare(viewer.canGoNext, false);
        compare(viewer.hasSidebar, false);
        backend.files = [
            {name: "a.png", path: "/x/a.png", url: "file:///x/a.png", kind: "image"},
            {name: "b.png", path: "/x/b.png", url: "file:///x/b.png", kind: "image"},
            {name: "c.png", path: "/x/c.png", url: "file:///x/c.png", kind: "image"}
        ];
        backend.startIndex = 1;
        backend.listing = false;
        compare(viewer.current, 1);
        compare(viewer.title, "b.png", "still the opened file");
        compare(viewer.subtitle, "2 of 3");
        compare(viewer.canGoNext, true);
        compare(viewer.canGoPrevious, true);
        viewer.go(1);
        compare(viewer.title, "c.png");
    }
}
