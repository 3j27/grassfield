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

    // A PDF in a window of its own: the page tools.
    QtObject {
        id: pdfBackend
        property var files: [{name: "two-pages.pdf", path: "/x/two-pages.pdf", url: Qt.resolvedUrl("../fixtures/print/two-pages.pdf"), kind: "pdf"}]
        property var errors: []
        property bool glance: false
        property bool browsing: true
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
            return {ok: true, kind: "pdf", name: files[i].name, url: files[i].url, size: "1 KB", type: "PDF document", modified: "today", folder: "/x"};
        }
    }

    Viewer {
        id: pdfViewer
        backend: pdfBackend
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

    // The window's structure as every app's (ADR-0024 amendment 2026-11-03): a floating sidebar panel in the sidebar fill, inset
    // from the window's left and bottom edges and rounded with the panel radius; the view runs straight on from its right edge.
    function test_theSidebarFloats() {
        viewer.sidebarOpen = true;
        wait(50);
        const inset = Tokens.windowSidebarPanelInset;
        const fill = findIn(viewer.contentItem, it => String(it).indexOf("SidebarPanel") === 0 && it.visible
                            && Qt.colorEqual(it.color, Appearance.colors.sidebarFill) && it.width === Tokens.previewSidebarWidth - inset);
        verify(fill !== null, "the sidebar panel, the sidebar's slot less its left gutter");
        const at = fill.mapToItem(viewer.contentItem, 0, 0);
        compare(at.x, inset, "inset from the window's left edge");
        compare(at.y, inset, "inset from the window's top edge: the panel runs the window's full height");
        compare(at.y + fill.height, viewer.contentItem.height - inset, "inset from the window's bottom edge");
        compare(fill.radius, Tokens.windowSidebarPanelRadius, "rounded as the panel token says");
        viewer.sidebarOpen = false;
    }

    // The lights sit in the corner of a shown sidebar's panel and the toolbar starts to its right; hidden, the lights move into the
    // toolbar (as Files).
    function test_lightsFollowTheSidebar() {
        const bars = [];
        const stack = [viewer.contentItem];
        while (stack.length > 0) {
            const it = stack.pop();
            if (it.contentStart !== undefined && it.controls !== undefined)
                bars.push(it);
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        compare(bars.length, 2, "the lights' toolbar over the sidebar and the one over the view");
        const sideBar = bars.find(b => b.objectName === "sidebarToolbar");
        const mainBar = bars.find(b => b !== sideBar);
        viewer.sidebarOpen = true;
        wait(50);
        verify(sideBar.visible && sideBar.showControls, "the lights are over the sidebar");
        verify(!mainBar.showControls, "none in the toolbar over the view");
        compare(sideBar.width, Tokens.previewSidebarWidth);
        compare(mainBar.x, Tokens.previewSidebarWidth, "the toolbar starts at the sidebar's right edge");
        compare(mainBar.x + mainBar.width, viewer.contentItem.width, "and runs to the window's right edge");
        viewer.sidebarOpen = false;
        wait(50);
        verify(!sideBar.visible, "no sidebar toolbar once the sidebar is hidden");
        verify(mainBar.showControls, "the lights moved into the toolbar");
        compare(mainBar.x, 0);
        compare(mainBar.width, viewer.contentItem.width);
    }

    // The page plate (macOS Preview, gs-092-232 at 1.0585 px/pt): a 164-pt plate in the 196-pt panel (16 pt from its edges), the page
    // 152 wide with 6 pt around it, the number in an 18-pt strip.
    function test_thePagePlateTokens() {
        const panel = Tokens.previewSidebarWidth - Tokens.windowSidebarPanelInset;
        const plate = panel - 4 * Tokens.spacingSm;
        compare(plate, 164);
        compare(Tokens.previewThumbnailWidth, plate - 2 * Tokens.previewPlatePad, "the page fills the plate less its padding");
        compare(Tokens.previewPlateCaption, 19);
        compare(Tokens.previewPlateRadius, 9);
    }

    // The toolbar's items never overlap at the minimum width, with the sidebar open or not, for both tool sets (a folder of images
    // and a PDF): a window too narrow for the sidebar plus the toolbar collapses the sidebar by itself, and shows it again when
    // it widens, if the user had it open.
    function test_narrowWindowCollapsesTheSidebar() {
        for (const v of [viewer, pdfViewer]) {
            v.sidebarOpen = true;
            v.width = v.minimumWidth;
            wait(300);
            verify(v.hasSidebar, v.title + ": has a sidebar");
            verify(v.sidebarOpen, v.title + ": the user's choice stays");
            verify(!v.showSidebar, v.title + ": collapsed at the minimum width (need " + v.toolbarNeed + ")");
            const toolbar = findIn(v.contentItem, it => it.contentStart !== undefined && it.controls !== undefined && it.objectName === "");
            const tools = findChild(v.contentItem, "toolsRow");
            const toggle = findIn(toolbar, it => it.accessibleName === "Thumbnails");
            verify(toggle !== null);
            const toggleRight = toggle.mapToItem(toolbar, toggle.width, 0).x;
            verify(tools.x >= toggleRight, v.title + ": the tools (x " + tools.x + ") clear the toggle (right " + toggleRight + ")");
            verify(tools.x + tools.width <= toolbar.width, v.title + ": the tools stay in the toolbar");
            // The toggle is off below the threshold (a client cannot resize its own window on Wayland) and on above it.
            verify(!toggle.enabled, v.title + ": the toggle is disabled in a window too narrow for the sidebar");
            verify(toggle.tooltip.indexOf("wider") >= 0, v.title + ": its tooltip says why: " + toggle.tooltip);
            const was = v.width;
            v.toggleSidebar();
            compare(v.sidebarOpen, true, v.title + ": the toggle changes nothing when it is off");
            compare(v.width, was, v.title + ": and never resizes the window");
            v.width = 900;
            wait(300);
            verify(v.showSidebar, v.title + ": the sidebar comes back when the window widens");
            const sideBar = findIn(v.contentItem, it => it.objectName === "sidebarToolbar");
            const toolbar2 = findIn(v.contentItem, it => it.contentStart !== undefined && it.controls !== undefined && it.objectName === "");
            const toggle2 = findIn(toolbar2, it => it.accessibleName === "Thumbnails");
            const tools2 = findChild(v.contentItem, "toolsRow");
            verify(tools2.x >= toggle2.mapToItem(toolbar2, toggle2.width, 0).x, v.title + ": clear with the sidebar shown");
            verify(toggle2.enabled, v.title + ": the toggle is enabled in a window wide enough");
            verify(toolbar2.x >= sideBar.width, v.title + ": the toolbar starts after the sidebar");
            v.sidebarOpen = false;
        }
    }

    // Preview never writes its own window's width (on Wayland the compositor keeps the size, so the layout would be wrong).
    function test_neverWritesItsOwnWidth() {
        for (const file of ["../../apps/preview/qml/Viewer.qml", "../../apps/preview/qml/Content.qml", "../../apps/preview/qml/Thumbnails.qml"]) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl(file), false);
            xhr.send();
            const lines = xhr.responseText.split("\n").filter(l => !/^\s*\/\//.test(l));
            for (const l of lines)
                verify(!/\b(viewerWin|Window\.window)\.(width|height)\s*=[^=]/.test(l), file + ": " + l);
        }
    }

    // The selection of a page or a file plate: the selection colour with its text (white on the deeper fill, ADR-0024), as the Settings
    // sidebar pill and the Files icon selection; never the accent with the accent's dark ink.
    function test_thePlateUsesTheSelectionPair() {
        for (const file of ["../../apps/preview/qml/Thumbnails.qml", "../../apps/preview/qml/Viewer.qml"]) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl(file), false);
            xhr.send();
            const text = xhr.responseText;
            verify(text.indexOf("Appearance.colors.selectionText") > 0, file + ": the selection text");
            verify(text.indexOf("Appearance.colors.accentText") < 0, file + ": no accent text");
        }
        const thumbs = Qt.resolvedUrl("../../apps/preview/qml/Thumbnails.qml");
        const x = new XMLHttpRequest();
        x.open("GET", thumbs, false);
        x.send();
        verify(x.responseText.indexOf("Appearance.colors.selection :") > 0, "the plate fill is the selection colour");
        verify(x.responseText.indexOf("Appearance.colors.hover, Appearance.inactiveSelectionOpacity") > 0, "neutral when not key");
        for (const dark of [false, true]) {
            const c = dark ? Appearance.accentedDark : Appearance.accentedLight;
            function lum(hex) {
                const ch = [1, 3, 5].map(i => {
                    const v = parseInt(hex.substr(i, 2), 16) / 255;
                    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
                });
                return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
            }
            const l1 = lum(c.selection), l2 = lum(c.selectionText);
            const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
            verify(ratio >= 4.5, (dark ? "dark" : "light") + " selection pair " + c.selection + " / " + c.selectionText + ": " + ratio);
        }
    }

    // The tokens behind every app's floating sidebar panel, measured on the macOS 26 System Settings capture (2 px/pt): an
    // 8-pt inset, an 18-pt corner concentric with the 26-pt window corner, and a calm fill 6 levels under the window.
    function test_theSidebarPanelTokens() {
        compare(Tokens.windowSidebarPanelInset, 8);
        compare(Tokens.windowSidebarPanelRadius, 18);
        compare(Tokens.windowSidebarPanelRadius, 26 - Tokens.windowSidebarPanelInset, "concentric with the window corner");
        // The rim is 1 pt and the shadow soft and light, as measured (ss-004-005): 242 at the edge on a 252 ground.
        compare(Tokens.windowSidebarPanelRimWidth, 1);
        compare(Tokens.windowSidebarPanelShadowBlur, 12);
        verify(Tokens.windowSidebarPanelShadowOpacity > 0.05 && Tokens.windowSidebarPanelShadowOpacity < 0.12, "light shadow strength");
        verify(Tokens.windowSidebarPanelShadowOpacityDark > Tokens.windowSidebarPanelShadowOpacity, "stronger in the dark");
        const light = Tokens.colorLight, dark = Tokens.colorDark;
        function level(hex) { return parseInt(hex.substring(1, 3), 16); }
        compare(level(light.windowBackground) - level(light.sidebarFill), 6, "light panel: 6 levels under the window");
        compare(level(dark.windowBackground) - level(dark.sidebarFill), 6, "dark panel: 6 levels under the window");
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
