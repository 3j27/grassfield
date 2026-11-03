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
        id: backendItem
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
        backend: backendItem
        globalMenu: false
    }

    // One image (a screenshot opened from Files): no sidebar toggle, so the title is the toolbar's first item after the lights.
    QtObject {
        id: soloBackend
        property var files: [{name: "Screenshot 2026-11-02 at 17.45.34.png", path: "/x/s.png", url: "file:///x/s.png", kind: "image"}]
        property var errors: []
        property bool glance: false
        property bool browsing: false
        property int startIndex: 0
        property bool dark: false
        property bool reduceMotion: true
        property bool increaseContrast: false
        property real textScale: 1
        property string accentColor: "multicolor"
        property string accentHighlight: "pink"
        property string shortcutStyle: "pc"
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
        function inspect(i) {
            return {ok: true, kind: "image", name: files[i].name, url: files[i].url, width: 3840, height: 2160, frames: 1, animated: false, size: "5 MB", type: "PNG image", modified: "today", folder: "/x"};
        }
    }

    Viewer {
        id: soloViewer
        backend: soloBackend
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
        const row = Tokens.previewSidebarItemHeight;
        backendItem.textScale = 1.3;
        compare(Tokens.previewSidebarItemHeight, Math.round(row * 1.3), "a PDF's file-name row grows with the text");
        compare(Appearance.textScale, 1.3);
        compare(title.font.pixelSize, Math.round(13 * 1.3), "the title follows Text size");
        backendItem.increaseContrast = true;
        verify(Appearance.increaseContrast);
        verify(Qt.colorEqual(subtitle.color, Appearance.colors.text), "secondary text in the text colour under Increase Contrast");
        backendItem.increaseContrast = false;
        backendItem.textScale = 1;
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

    // The title starts after the traffic lights (the toolbar's contentStart, the inset every app's leading items use), with and
    // without the sidebar toggle in front of it; with no toggle it once started at the toolbar's left edge, under the lights.
    function test_theTitleStartsAfterTheLights() {
        verify(!soloViewer.hasSidebar, "the solo window has no sidebar toggle");
        for (const v of [viewer, soloViewer]) {
            const toolbar = findIn(v.contentItem, it => it.contentStart !== undefined && it.controls !== undefined);
            verify(toolbar !== null, "the unified toolbar");
            const title = textOf(v.contentItem, v.title);
            verify(title !== null, "the title text of " + v.title);
            verify(toolbar.contentStart > 0, "the lights reserve room");
            const x = title.mapToItem(toolbar, 0, 0).x;
            verify(x >= toolbar.contentStart, v.title + ": title x " + x + " is under the lights (contentStart " + toolbar.contentStart + ")");
            verify(x + title.width <= v.width, "title stays in the window");
        }
    }

    function test_toolbarRightIsLaidOut() {
        const tools = findChild(viewer.contentItem, "toolsRow");
        verify(tools !== null);
        verify(tools.width > 0, "tools width " + tools.width);
        verify(tools.x + tools.width <= viewer.width);
        wait(300);
        const img = grabImage(viewer.contentItem);
        // A capture for the visual review where the dev tree has its .dev/ (a fresh checkout has none, and the capture is not
        // what this test checks).
        try {
            img.save(Qt.resolvedUrl("../../.dev/b2-viewer.png").toString().replace("file://", ""));
        } catch (e) {
            console.log("b2-viewer.png not saved: " + e);
        }
    }

    function findIn(item, test) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (test(it))
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // The window's structure as every app's (ADR-0039 step 16): an edge-to-edge sidebar in the sidebar fill, toolbar groups on
    // the toolbar's rimmed capsules with 34-pt buttons, and the toolbar's rule once the view's content has scrolled under it.
    function test_theSidebarIsEdgeToEdge() {
        viewer.sidebarOpen = true;
        wait(50);
        const fill = findIn(viewer.contentItem, it => String(it).indexOf("QQuickRectangle") === 0 && it.visible
                            && Qt.colorEqual(it.color, Appearance.colors.sidebarFill) && it.width === Tokens.previewSidebarWidth);
        verify(fill !== null, "the sidebar fill, as wide as the sidebar");
        const at = fill.mapToItem(viewer.contentItem, 0, 0);
        compare(at.x, 0, "flush with the window's left edge");
        compare(at.y + fill.height, viewer.contentItem.height, "down to the window's bottom edge");
        compare(fill.radius, 0, "no floating panel");
        viewer.sidebarOpen = false;
    }

    function test_theToolbarGroupsAreTheSharedCapsules() {
        const groups = [];
        const stack = [viewer.contentItem];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.fillOpacity !== undefined && it.hairline !== undefined && it.visible && it.height === Tokens.toolbarCapsule)
                groups.push(it);
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        verify(groups.length >= 3, "the toolbar's groups: " + groups.length);
        for (const g of groups) {
            const button = findIn(g, it => it !== g && it.buttonSize !== undefined && it.visible);
            if (button)
                compare(button.buttonSize, Tokens.toolbarGroupButton, "a group button is 34");
        }
    }

    function test_theToolbarRuleShowsOnceScrolled() {
        const rule = findIn(viewer.contentItem, it => it.objectName === "toolbarRule");
        verify(rule !== null);
        compare(rule.height, Tokens.appsBorderWidth);
        verify(viewer.view !== null && viewer.view.scrolled !== undefined, "the view says whether it has scrolled");
        tryVerify(() => rule.visible === (viewer.view.scrolled === true), 1000, "the rule follows the view");
    }
}
