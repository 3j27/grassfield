import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"

// The Preview window with a mock backend: browsing state, title and subtitle, no wrap at the ends.
TestCase {
    id: testCase
    name: "PreviewViewer"
    when: viewer.visible

    QtObject {
        id: backend
        property var files: [
            {name: "a.png", path: "/x/a.png", url: "file:///x/a.png", kind: "image"},
            {name: "b.png", path: "/x/b.png", url: "file:///x/b.png", kind: "image"},
            {name: "c.png", path: "/x/c.png", url: "file:///x/c.png", kind: "image"}
        ]
        property var errors: []
        property bool glance: false
        property bool browsing: true
        property int startIndex: 1
        property bool dark: true
        property bool reduceMotion: true
        function inspect(i) {
            return {ok: true, kind: "image", name: files[i].name, url: files[i].url, width: 1200, height: 800, frames: 1, animated: false, size: "1 MB", type: "PNG image", modified: "today", folder: "/x"};
        }
    }

    Viewer {
        id: viewer
        backend: backend
        globalMenu: false
    }

    function test_startsAtOpenedFile() {
        compare(viewer.current, 1);
        compare(viewer.title, "b.png");
        compare(viewer.subtitle, "2 of 3");
        verify(!viewer.sidebarOpen, "the folder of one image starts without the sidebar");
    }

    function test_goStopsAtEnds() {
        viewer.go(1);
        compare(viewer.current, 2);
        viewer.go(1);
        compare(viewer.current, 2);
        compare(viewer.canGoNext, false);
        viewer.go(-5);
        compare(viewer.current, 0);
        compare(viewer.canGoPrevious, false);
        viewer.go(1);
    }

    function test_toolbarRightIsLaidOut() {
        const tools = findChild(viewer.contentItem, "toolsRow");
        verify(tools !== null);
        verify(tools.width > 0, "tools width " + tools.width);
        verify(tools.x + tools.width <= viewer.width);
        wait(300);
        const img = grabImage(viewer.contentItem);
        img.save(Qt.resolvedUrl("../../.dev/b2-viewer.png").toString().replace("file://", ""));
    }
}
