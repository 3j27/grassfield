import QtQuick
import QtTest
import Grassfield.Ui
import "store"

// Grassfield Store's window (apps/store/qml/Main.qml, ADR-0037 step 2) with a fake backend: the sidebar's items from the
// catalog's sections, Back and Forward with the scroll kept, the search while typing (and Esc), the pages --page opens,
// the keyboard shortcuts, the accessible names, the offline notice, the product page's links and facts, and a new snapshot
// keeping the page. Nothing installs, opens or fetches anything.
TestCase {
    id: testCase
    name: "StoreMain"
    width: 800
    height: 600
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        FakeStoreBackend {}
    }

    function make(props) {
        const backend = fakeBackend.createObject(testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, Object.assign({backend: backend, globalMenu: false}, props || {}));
        verify(win);
        // The keyboard to this window (offscreen Qt moves the focus window on requestActivate), as tst_filesbrowser.qml.
        win.requestActivate();
        tryVerify(() => win.active, 2000, "the window is active");
        wait(50);
        tryVerify(() => win.page !== null);
        return {backend: backend, win: win};
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function findAll(item, pred, out) {
        out = out || [];
        if (!item)
            return out;
        if (pred(item))
            out.push(item);
        for (const k of item.children || [])
            findAll(k, pred, out);
        return out;
    }

    // The sidebar: Discover, then the catalog's other sections, Categories and Updates; Discover selected first.
    function test_sidebar() {
        const t = make();
        compare(t.win.sidebarItems.map(i => i.key), ["section:discover", "section:play", "categories", "updates"]);
        compare(t.win.sidebarItems[0].icon, "sparkle");
        compare(t.win.sidebarItems[1].icon, "gamecontroller");
        compare(t.win.pageKind, "section");
        compare(t.win.page.section.id, "discover");
        verify(!t.win.canBack);
    }

    // The carousels' arrows show only while the pointer is over them (never at rest, never in the Tab chain).
    function test_carouselArrowsAtRest() {
        const t = make();
        const arrows = findAll(t.win.page, i => i.back !== undefined && i.shown !== undefined);
        verify(arrows.length >= 2);
        for (const a of arrows) {
            verify(!a.shown, "not shown at rest");
            tryCompare(a, "visible", false);
            compare(a.focusPolicy, Qt.NoFocus);
        }
    }

    // A built-in Discover (no catalog) is titled by the window, in the session's language.
    function test_builtInDiscover() {
        const t = make();
        t.backend.sectionList = [{id: "discover", title: "", builtIn: true, symbol: "discover", blocks: [{kind: "row", title: "Graphics",
            category: "graphics", apps: [t.backend.find("org.example.Paint")]}]}];
        t.backend.dataChanged();
        compare(t.win.sidebarItems[0].title, "Discover");
        compare(t.win.page.title, "Discover");
        compare(t.win.sidebarItems.length, 3);
    }

    // Back and Forward: a page left keeps its scroll; a sidebar row starts a new page.
    function test_backForwardKeepsScroll() {
        const t = make({height: 400});
        const discover = t.win.page;
        tryVerify(() => discover.flickable.contentHeight > discover.flickable.height);
        discover.scroll = 120;
        t.win.openApp("org.example.Paint");
        compare(t.win.pageKind, "app");
        verify(t.win.canBack);
        compare(t.win.current.tab, "section:discover", "a product page keeps its sidebar row");
        t.win.goBack();
        compare(t.win.pageKind, "section");
        tryCompare(t.win.page, "scroll", 120);
        verify(t.win.canForward);
        t.win.goForward();
        compare(t.win.pageKind, "app");
        t.win.pick("section:play");
        compare(t.win.page.section.id, "play");
        verify(!t.win.canForward);
    }

    // Typing searches at once; each key changes the results page in place; clearing goes back; Esc clears, then leaves.
    function test_searchWhileTyping() {
        const t = make();
        t.win.focusSearch();
        verify(t.win.searchField.activeFocus);
        keyClick("p");
        compare(t.win.pageKind, "search");
        compare(t.win.page.query, "p");
        const backs = t.win.nav.back.length;
        keyClick("a");
        compare(t.win.pageKind, "search");
        compare(t.win.page.query, "pa");
        compare(t.win.page.results.map(a => a.id), ["org.example.Paint", "org.example.Tool"]); // Paint, Pack Tool
        compare(t.win.page.title, "Results for “pa”");
        compare(t.win.nav.back.length, backs, "one page for the whole query");
        keyClick(Qt.Key_Escape);
        compare(t.win.searchField.text, "");
        compare(t.win.pageKind, "section");
        verify(t.win.searchField.activeFocus);
        keyClick(Qt.Key_Escape);
        verify(!t.win.searchField.activeFocus, "the second Esc leaves the field");
        // No result.
        t.win.focusSearch();
        keyClick("z");
        keyClick("z");
        compare(t.win.page.results.length, 0);
        compare(t.win.page.Accessible.name, "No Results for “zz”");
        // An app opened from the results, then Back: the results and the query come back.
        t.win.focusSearch();
        keyClick(Qt.Key_Backspace);
        keyClick(Qt.Key_Backspace);
        keyClick("g");
        compare(t.win.page.results.map(a => a.id), ["org.example.Games"]);
        t.win.openApp("org.example.Games");
        compare(t.win.searchField.text, "g", "the field keeps its text while the app's page shows");
        t.win.goBack();
        compare(t.win.pageKind, "search");
        compare(t.win.searchField.text, "g");
        compare(t.win.page.query, "g");
    }

    // --page and the pages it names.
    function test_openPage() {
        const t = make({startPage: "category:graphics"});
        compare(t.win.pageKind, "category");
        compare(t.win.page.title, "Graphics");
        compare(t.win.page.apps.length, 2);
        compare(t.win.current.tab, "categories");
        t.win.openPage("app:org.example.Paint");
        compare(t.win.pageKind, "app");
        compare(t.win.page.app.name, "Paint");
        verify(t.backend.calls.indexOf("info:paint") >= 0, "pacman -Si asked for when the page opens");
        t.backend.packageInfo("paint", {version: "2.0-1", downloadSize: "12.4 MB", installedSize: "40 MB", buildDate: "October 15, 2026"});
        compare(t.win.page.facts.version, "2.0-1");
        t.backend.packageInfo("other", {version: "9"});
        compare(t.win.page.facts.version, "2.0-1", "another package's answer is not this page's");
        t.win.openPage("installed");
        compare(t.win.pageKind, "installed");
        compare(t.win.page.groups.length, 2);
        t.win.openPage("updates");
        compare(t.win.pageKind, "updates");
        compare(t.win.page.apps.length, 1);
        t.win.openPage("search:photo");
        compare(t.win.pageKind, "search");
        compare(t.win.searchField.text, "photo");
        t.win.openPage("categories");
        compare(t.win.pageKind, "categories");
        compare(t.win.page.categories.length, 2);
        t.win.openPage("section:play");
        compare(t.win.page.section.id, "play");
    }

    // --page before the first data: it waits for them (a section's row exists only then).
    function test_startPageWaitsForData() {
        const backend = fakeBackend.createObject(testCase, {revision: 0, loading: true});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/Main.qml"));
        const win = createTemporaryObject(comp, testCase, {backend: backend, globalMenu: false, startPage: "section:play"});
        tryVerify(() => win.page !== null);
        compare(win.page.section.id, "discover");
        const fake = backend as FakeStoreBackend;
        fake.revision = 1;
        fake.loading = false;
        fake.dataChanged();
        compare(win.page.section.id, "play");
        compare(win.current.tab, "section:play");
    }

    // The category page's source filter.
    function test_categoryFilter() {
        const t = make({startPage: "category:graphics"});
        compare(t.win.page.kinds, ["repo"]);
        t.win.page.kindPicked("repo");
        compare(t.win.current.kind, "repo");
        compare(t.win.page.shown.length, 2);
    }

    // The keyboard (spec "Keyboard").
    function test_shortcuts() {
        const t = make();
        keyClick(Qt.Key_2, Qt.ControlModifier);
        compare(t.win.page.section.id, "play");
        keyClick(Qt.Key_3, Qt.ControlModifier);
        compare(t.win.pageKind, "categories");
        keyClick(Qt.Key_BracketLeft, Qt.ControlModifier);
        compare(t.win.page.section.id, "play");
        keyClick(Qt.Key_Left, Qt.AltModifier);
        compare(t.win.page.section.id, "discover");
        keyClick(Qt.Key_Right, Qt.AltModifier);
        compare(t.win.page.section.id, "play");
        keyClick(Qt.Key_R, Qt.ControlModifier);
        verify(t.backend.calls.indexOf("refresh") >= 0);
        keyClick(Qt.Key_F, Qt.ControlModifier);
        verify(t.win.searchField.activeFocus);
        keyClick(Qt.Key_Comma, Qt.ControlModifier);
        verify(t.win.settingsWindow && t.win.settingsWindow.visible);
        t.win.settingsWindow.close();
    }

    // Accessible names: the buttons say what they would do, a lockup its name, source and summary.
    function test_accessibleNames() {
        const t = make({startPage: "category:graphics"});
        tryVerify(() => findAll(t.win.page, i => i.Accessible.role === Accessible.Button && i.Accessible.name === "Get Paint").length === 1);
        verify(findAll(t.win.page, i => i.Accessible.name === "Open Photo Lab").length === 1);
        verify(findAll(t.win.page, i => i.Accessible.name === "Paint, Arch Linux · extra, Paint does one thing well").length === 1);
        // Installing comes with step 3: the buttons are there, disabled, and say why.
        const get = findAll(t.win.page, i => i.Accessible.name === "Get Paint")[0];
        verify(!get.enabled);
        compare(get.Accessible.description, "Installing and opening apps from the Store come in a later version.");
        t.win.openPage("app:org.example.Tool");
        verify(findAll(t.win.page, i => i.Accessible.name === "Pack Tool is installed").length === 1, "installed without a launcher");
    }

    // Offline (SR29), and a catalog older than 30 days.
    function test_notices() {
        const t = make();
        const notice = find(t.win.contentItem, i => i.Accessible.role === Accessible.AlertMessage && i.text !== undefined && i.radius !== undefined);
        verify(notice);
        compare(notice.text, "");
        verify(!notice.visible);
        t.backend.online = false;
        compare(notice.text, "You're offline. The catalog is from October 27.");
        verify(notice.visible);
        t.backend.online = true;
        t.backend.catalog = {inUse: true, problem: "", channel: "stable", date: "August 1", old: true};
        compare(notice.text, "The catalog is from August 1 and may be out of date.");
        t.backend.catalog = {inUse: false, problem: "unconfigured", channel: "stable", date: "", old: false};
        t.backend.online = false;
        compare(notice.text, "You're offline.");
    }

    // The product page's links go to the backend (which opens https only, never in a dev session).
    function test_productLinks() {
        const t = make({startPage: "app:org.example.Paint"});
        const info = findAll(t.win.page, i => i.link !== undefined && i.label === "Homepage");
        compare(info.length, 1);
        compare(info[0].value, "example.org");
        info[0].linkActivated(info[0].link);
        compare(t.backend.links, ["https://example.org/org.example.Paint"]);
        const rating = findAll(t.win.page, i => i.label === "Content Rating");
        compare(rating[0].value, "Online interaction: intense");
        const languages = findAll(t.win.page, i => i.label === "Languages");
        compare(languages[0].value, "Deutsch, français");
    }

    // A new snapshot keeps the page and its scroll; an app no longer offered shows an empty page, not an error.
    function test_newSnapshotKeepsThePage() {
        const t = make({startPage: "category:graphics"});
        t.backend.dataChanged();
        compare(t.win.pageKind, "category");
        compare(t.win.page.title, "Graphics");
        t.win.openPage("app:org.example.Gone");
        compare(t.win.pageKind, "app");
        compare(Object.keys(t.win.page.app).length, 0);
    }

    // The local user's row opens Installed and shows as selected; no sidebar row is.
    function test_accountRow() {
        const t = make();
        t.win.openInstalled();
        compare(t.win.pageKind, "installed");
        compare(t.win.current.tab, "");
        const row = find(t.win.contentItem, i => i.Accessible.name === "Ada Lovelace: Installed apps");
        verify(row);
    }

    // Larger text (Settings > Accessibility > Display, 1.3): the hero's and the cards' titles keep a line height for their
    // size and their room under the eyebrow.
    function test_largeText() {
        const t = make();
        t.backend.textScale = 1.3;
        const titles = findAll(t.win.page, i => i.lineHeightMode === Text.FixedHeight && i.visible && i.text !== "");
        verify(titles.length > 1);
        for (const title of titles) {
            verify(title.lineHeight >= title.font.pixelSize * 1.05, "line height " + title.lineHeight + " for " + title.font.pixelSize);
            const eyebrow = title.parent.children.find(i => i.font && i.font.capitalization === Font.AllUppercase);
            verify(eyebrow);
            const capTop = title.y + title.baselineOffset - title.font.pixelSize * 0.7;
            verify(capTop - (eyebrow.y + eyebrow.height) > 4, "room under the eyebrow: " + (capTop - eyebrow.y - eyebrow.height));
        }
        t.backend.textScale = 1;
    }

    // The keyboard brings what it focuses into view, below the toolbar (as macOS): Tab to an item below the fold scrolls
    // down to it, and an item above the view scrolls back up.
    function test_focusScrollsIntoView() {
        const t = make({height: 400});
        const page = t.win.page;
        tryVerify(() => page.flickable.contentHeight > page.flickable.height);
        const focusable = findAll(page, i => i.activeFocusOnTab === true && i.visible && i.width > 0);
        verify(focusable.length > 2);
        const shown = item => {
            const r = item.mapToItem(page, 0, 0, item.width, item.height);
            return r.y >= Tokens.windowUnifiedHeight && r.y + r.height <= page.height;
        };
        const below = focusable.filter(i => !shown(i));
        verify(below.length > 0, "some items start below the fold");
        // Tab through the page: each item it focuses is in view; some of them were below the fold.
        focusable[0].forceActiveFocus(Qt.TabFocusReason);
        let reached = 0;
        for (let k = 0; k < focusable.length; k++) {
            keyClick(Qt.Key_Tab);
            const f = focusable.find(i => i.activeFocus);
            if (!f)
                break; // left the page (the toolbar or the sidebar)
            tryVerify(() => shown(f), 2000, "a focused item is in view");
            if (below.includes(f))
                reached++;
        }
        verify(reached > 0, "Tab reached an item that was below the fold");
        verify(page.scroll > 0);
        // Back up: the first item comes back into view.
        focusable[0].forceActiveFocus(Qt.BacktabFocusReason);
        tryVerify(() => shown(focusable[0]), 2000, "the first item is back in view");
    }
}
