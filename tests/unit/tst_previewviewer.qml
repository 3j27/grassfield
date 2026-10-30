import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"

// The Preview window with a mock backend: browsing state, title and subtitle, no wrap at the ends; the window neutrals,
// Increase Contrast, Text size and the text highlight colour, as in every app (ADR-0039 step 3).
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
        property bool increaseContrast: false
        property real textScale: 1
        property string accentColor: "multicolor"
        // A highlight colour of its own, so the text selection cannot pass for the accent.
        property string accentHighlight: "pink"
        property string shortcutStyle: "pc"
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
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

    // The first Text under `item` whose text is `text`.
    function textOf(item, text) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.text === text && it.font !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_windowDrawsTheWindowNeutrals() {
        verify(Appearance.windowSurface, "Preview is an app window (ADR-0024), not a shell material");
        verify(Qt.colorEqual(viewer.color, Appearance.colors.windowBackground), "window " + viewer.color);
        const subtitle = textOf(viewer.contentItem, viewer.subtitle);
        verify(subtitle !== null);
        verify(Qt.colorEqual(subtitle.color, Appearance.colors.windowTextSecondary), "subtitle " + subtitle.color);
    }

    function test_followsIncreaseContrastAndTextSize() {
        const title = textOf(viewer.contentItem, viewer.title);
        verify(title !== null);
        const subtitle = textOf(viewer.contentItem, viewer.subtitle);
        compare(title.font.pixelSize, Tokens.typographyBodySize);
        backend.textScale = 1.3;
        compare(Appearance.textScale, 1.3);
        compare(title.font.pixelSize, Math.round(13 * 1.3), "the title follows Text size");
        backend.increaseContrast = true;
        verify(Appearance.increaseContrast);
        verify(Qt.colorEqual(subtitle.color, Appearance.colors.text), "secondary text in the text colour under Increase Contrast");
        backend.increaseContrast = false;
        backend.textScale = 1;
        compare(title.font.pixelSize, Tokens.typographyBodySize);
    }

    function test_textSelectionUsesTheHighlightColour() {
        verify(!Qt.colorEqual(Appearance.highlight, Appearance.colors.accent), "the pink highlight is not the accent");
        const stack = [viewer.contentItem];
        let inputs = 0;
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.selectionColor !== undefined) {
                inputs++;
                verify(Qt.colorEqual(it.selectionColor, Appearance.highlight), "selection " + it.selectionColor);
                verify(Qt.colorEqual(it.selectedTextColor, Appearance.highlightText));
            }
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        verify(inputs > 0, "the search field at least");
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
