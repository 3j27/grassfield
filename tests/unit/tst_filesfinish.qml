import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml" as FilesQml

// Files' finish (ADR-0039 step 23; audit §3.19): Increase Contrast and Text size reach Files; the toolbar's capsules and search
// are step 14's rimmed capsule, the search with the shared ring outside it and a clear button; the path bar's segments take the
// keyboard; the window's secondary text, the Customize Folder wells, the tags ring, the loading note in the view and the
// preview pane's actions are read in the source (their hosts need the whole FilesApp). The list's sort keeps its keyboard path
// in View > Sort By, as macOS (the headers are no Tab stops without Full Keyboard Access).
TestCase {
    id: tc

    name: "FilesFinish"
    width: 500
    height: 200
    visible: true
    when: windowShown

    QtObject {
        id: tabStub

        property var segments: [{label: "Home", url: "file:///home/me"}, {label: "Documents", url: "file:///home/me/Documents"}]
        property string navigated: ""
        property string searchText: ""
        property var activeFolder: ({count: 0, selectedCount: 0})
        property var app: QtObject {
            function isRecents(url) {
                return false;
            }
        }

        function navigate(url, push) {
            tabStub.navigated = url;
        }

        function setSearch(text) {
            tabStub.searchText = text;
        }

        function focusView() {
        }
    }

    FilesQml.PathBar {
        id: pathBar
        y: 120
        width: 400
        height: Tokens.filesPathBarHeight
        tab: tabStub
    }

    Row {
        x: 10
        y: 10
        spacing: 10

        FilesQml.NavCapsule {
            id: nav
            tab: null
        }

        FilesQml.SearchCapsule {
            id: search
            tab: tabStub
        }
    }

    Component {
        id: appearanceComponent
        FilesQml.FilesAppearance {}
    }

    function appStub(extra) {
        const app = {dark: false, reduceMotion: false, accentColor: "multicolor", accentHighlight: "automatic", shortcutStyle: "pc",
                     iconMode: "default", iconTint: "accent", folderColor: "theme"};
        for (const k in extra)
            app[k] = extra[k];
        return app;
    }

    function cleanup() {
        tabStub.searchText = "";
        tabStub.navigated = "";
        Appearance.textScale = 1;
        Appearance.increaseContrast = false;
    }

    function find(root, test) {
        const stack = [root];
        while (stack.length > 0) {
            const it = stack.shift();
            if (test(it))
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_filesReadsIncreaseContrastAndTextSize() {
        const a = createTemporaryObject(appearanceComponent, tc, {app: appStub({increaseContrast: true, textScale: 1.3})});
        verify(a !== null);
        compare(Appearance.increaseContrast, true);
        compare(Appearance.textScale, 1.3);
        compare(Tokens.filesIconLabelSize, Math.round(12 * 1.3), "the icon view's names follow Text size");
        a.destroy();
        wait(0);
        // A host without the settings (a test's stand-in) reads the defaults.
        const b = createTemporaryObject(appearanceComponent, tc, {app: appStub({})});
        compare(Appearance.increaseContrast, false);
        compare(Appearance.textScale, 1);
        b.destroy();
    }

    function test_theToolbarCapsulesAreRimmed() {
        compare(nav.fillOpacity, Tokens.toolbarCapsuleFillOpacity);
        verify(!nav.field, "a lifted capsule, not a field");
        compare(nav.border.width, Appearance.increaseContrast ? Tokens.controlBorderWidth : 0, "no outline in the standard appearance");
        tc.forceActiveFocus(); // the window may give the field the first focus
        tryVerify(() => !search.expanded, 1000, "collapsed without the focus or text");
        compare(search.fillOpacity, Tokens.toolbarCapsuleFillOpacity, "collapsed: a button of the toolbar");
        tryCompare(search, "width", Tokens.toolbarCapsule);
    }

    function test_theSearchOpensRingsAndClears() {
        const ring = find(search, it => it.shapeRadius !== undefined && it.border !== undefined && it.anchors.margins === -Tokens.controlFocusOutline);
        verify(ring !== null, "the shared focus ring");
        verify(!ring.visible);
        search.focusField();
        tryVerify(() => search.expanded);
        compare(search.fillOpacity, Tokens.toolbarCapsuleFillOpacity, "open: still the lifted toolbar capsule");
        verify(!search.field, "no flat field in a toolbar");
        verify(ring.visible, "the ring outside the field while it has the focus");
        const clear = find(search, it => it.objectName === "clearButton");
        verify(clear !== null);
        verify(!clear.visible, "no clear button without text");
        keyClick(Qt.Key_A);
        keyClick(Qt.Key_B);
        compare(tabStub.searchText, "ab");
        verify(clear.visible, "the clear button with text");
        mouseClick(clear);
        compare(tabStub.searchText, "", "cleared");
        const field = find(search, it => it.cursorVisible !== undefined && it.selectByMouse !== undefined);
        verify(field.activeFocus, "the field keeps the focus");
        compare(field.text, "");
    }

    function segments() {
        const out = [];
        const stack = [pathBar];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.Accessible.role === Accessible.Button && it.activeFocusOnTab)
                out.push(it);
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return out;
    }

    function test_thePathBarTakesTheKeyboard() {
        tryVerify(() => segments().length === 2, 1000, "each segment a Tab stop");
        const home = segments()[0];
        home.forceActiveFocus(Qt.TabFocusReason);
        const ring = find(home, it => it.shapeRadius !== undefined && it.anchors.margins === -Tokens.controlFocusOutline);
        verify(ring !== null && ring.visible, "the ring on keyboard focus");
        keyClick(Qt.Key_Return);
        compare(tabStub.navigated, "file:///home/me");
        keyClick(Qt.Key_Tab);
        verify(segments()[1].activeFocus, "Tab moves to the next segment");
        keyClick(Qt.Key_Space);
        compare(tabStub.navigated, "file:///home/me/Documents");
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_theWindowsSecondaryText_data() {
        // ColumnView, FileList and PrintSheet followed once #67 merged.
        return ["AccessAlert", "BrowserWindow", "ColumnView", "CustomizeFolderWindow", "FileList", "FilePanel", "GalleryView", "GoToFolderPanel", "IconView",
                "InfoWindow", "KioSheets", "PathBar", "PreviewPane", "PrintSheet", "ProgressWindow", "ScopeBar", "SearchCapsule", "Sidebar", "TabBar"].map(n => ({tag: n, path: "apps/files/qml/" + n + ".qml"}));
    }

    function test_theWindowsSecondaryText(data) {
        compare(source(data.path).indexOf("colors.textSecondary"), -1, "the window's secondary colour, not the glass one");
    }

    function test_theRestInTheSource() {
        const customize = source("apps/files/qml/CustomizeFolderWindow.qml");
        compare(customize.indexOf("Tokens.materialFillOpacity"), -1, "Customize Folder's wells are no longer the dark fill");
        compare(customize.split("Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)").length - 1, 2, "both wells on the appearance's fill");
        compare(customize.split("FocusRing {").length - 1, 2, "both wells ring outside");
        const pane = source("apps/files/qml/PreviewPane.qml");
        compare(pane.indexOf("shapeRadius: 0"), -1, "the tags ring is rounded");
        verify(/delegate: Item \{\s*id: action[\s\S]*?activeFocusOnTab: true[\s\S]*?ActivationKeys\.activation[\s\S]*?KeyFocus/.test(pane), "the preview pane's actions take the keyboard");
        const tab = source("apps/files/qml/BrowserTab.qml");
        verify(/id: loadingNote[\s\S]*?Tokens\.filesLoadingDelay[\s\S]*?Spinner \{/.test(tab), "a slow listing shows the shared spinner in the view");
        const win = source("apps/files/qml/BrowserWindow.qml");
        // Share, Tags and Action are bare glyphs with no capsule, as macOS 27 Finder draws them on a white window (Share since
        // ADR-0045 OC-13, while LocalSend is installed).
        verify(/Item \{[^}]*?\n\s*Row \{[^}]*?ToolButton \{\s*id: shareButton[\s\S]*?ToolButton \{\s*id: tagsButton[\s\S]*?ToolButton \{\s*id: actionButton/.test(win), "Share, Tags and Action in a row");
        verify(!/RimmedCapsule \{\s*width: 2 \* Tokens\.toolbarCapsule/.test(win), "no capsule round Tags and Action");
        compare(win.indexOf("Appearance.buttonFill"), -1, "no plain capsule left in the toolbar");
        const tabs = source("apps/files/qml/TabBar.qml");
        verify(tabs.indexOf("!Appearance.reduceMotion") > 0 && tabs.indexOf("Easing.OutQuad") < 0, "the tabs do not slide under Reduce Motion, and move on the move curve");
    }
}
