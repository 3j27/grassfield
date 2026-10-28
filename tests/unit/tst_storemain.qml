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

    // The AUR (SR7), while it is on: Return asks it for the query; its results come in their own section with their votes
    // and the out-of-date flag; an answer for another query is dropped; nothing of it while the AUR is off.
    function test_aurSearchAfterReturn() {
        const t = make();
        t.win.focusSearch();
        keyClick("e");
        keyClick("x");
        verify(!t.win.page.aurOn);
        keyClick(Qt.Key_Return);
        verify(t.backend.calls.indexOf("searchAur:ex") < 0, "the AUR off: never asked");
        verify(findAll(t.win.page, i => i.text === "Press Return to search the AUR too." && i.visible).length === 0);

        t.backend.sources = {aur: true, flathub: false, flatpak: false, screenshots: true};
        t.win.focusSearch();
        keyClick(Qt.Key_End);
        keyClick("a");
        compare(t.win.page.query, "exa");
        verify(t.win.page.aurOn);
        compare(t.win.page.aurLine(), "Press Return to search the AUR too.");
        keyClick(Qt.Key_Return);
        verify(t.backend.calls.indexOf("searchAur:exa") >= 0);
        compare(t.win.page.aurState, "asking");
        compare(t.win.page.aurLine(), "Searching the AUR…");
        t.backend.aurResults("ex", [{id: "aur:old", name: "old"}], "");
        compare(t.win.page.aurResults.length, 0, "an answer for another query is dropped");
        t.backend.aurResults("exa", [
            {id: "aur:example-app-bin", name: "example-app-bin", summary: "An example app", icon: "", kind: "aur", repo: "",
             installed: false, launcher: false, votes: 120, outOfDate: false},
            {id: "aur:example-tool-git", name: "example-tool-git", summary: "A tool", icon: "", kind: "aur", repo: "",
             installed: false, launcher: false, votes: 7, outOfDate: true}], "");
        compare(t.win.page.aurState, "done");
        compare(t.win.page.title, "Results for “exa”");
        verify(findAll(t.win.page, i => i.text === "From the AUR (not reviewed)" && i.visible).length === 1);
        verify(findAll(t.win.page, i => i.text === "AUR · 120 votes").length === 1);
        verify(findAll(t.win.page, i => i.text === "AUR · 7 votes · Flagged out of date").length === 1);
        compare(t.win.page.aurLine(), "");
        // Typing goes on: the AUR's section empties until Return asks again.
        t.win.focusSearch();
        keyClick(Qt.Key_End);
        keyClick("m");
        compare(t.win.page.aurState, "");
        compare(t.win.page.aurResults.length, 0);
        keyClick(Qt.Key_Return);
        t.backend.aurResults("exam", [], "tooMany");
        compare(t.win.page.aurLine(), "The AUR has too many results for “exam”: type more of the name.");
        compare(t.win.page.Accessible.name, "No Results for “exam”");
    }

    // An AUR page (SR11): the AUR's facts asked when it opens and read again when they come; View Build Script fetches the
    // PKGBUILD and shows it as text.
    function test_aurProductPage() {
        const t = make({startPage: "app:aur:example-app-bin"});
        tryVerify(() => t.win.pageKind === "app");
        verify(t.backend.calls.indexOf("requestAur:aur:example-app-bin") >= 0);
        compare(findAll(t.win.page, i => i.label === "Maintainer")[0].value, "alice");
        compare(findAll(t.win.page, i => i.label === "Votes")[0].value, "120");
        compare(findAll(t.win.page, i => i.label === "Version")[0].value, "2.4.1-1");
        compare(findAll(t.win.page, i => i.label === "Flagged Out of Date").length, 0);
        t.backend.aurRead = true;
        t.backend.aurInfo("aur:example-app-bin");
        compare(findAll(t.win.page, i => i.label === "Flagged Out of Date")[0].value, "October 3, 2026");
        const view = findAll(t.win.page, i => i.text === "View Build Script" && i.visible)[0];
        verify(view);
        view.clicked();
        verify(t.backend.calls.indexOf("buildScript:aur:example-app-bin") >= 0);
        const sheet = findAll(t.win.contentItem, i => i.confirmEnabled !== undefined && i.text === "Loading…")[0];
        verify(sheet && sheet.visible);
        compare(sheet.title, "Build Script of “example-app-bin”");
        t.backend.buildScript("aur:other", "not this one", true);
        compare(sheet.text, "Loading…");
        t.backend.buildScript("aur:example-app-bin", "pkgname=example-app-bin\n", true);
        compare(sheet.text, "pkgname=example-app-bin\n");
        sheet.close();
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
        // Get acts (step 3); a Get the Store cannot act on is disabled and says why (a dev session without the fake programs).
        const get = findAll(t.win.page, i => i.Accessible.name === "Get Paint")[0];
        verify(get.enabled);
        compare(get.Accessible.description, "");
        t.backend.blocks = {"org.example.Paint": {get: "dev"}};
        t.backend.revision++;
        verify(!get.enabled);
        compare(get.Accessible.description, "dev: not applied");
        t.win.openPage("app:org.example.Tool");
        verify(findAll(t.win.page, i => i.Accessible.name === "Pack Tool is installed").length === 1, "installed without a launcher");
    }

    // Offline (SR29), and a catalog older than 30 days.
    function test_notices() {
        const t = make();
        const notice = find(t.win.contentItem, i => i.objectName === "offlineNotice");
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

    // The global menu (made only while a registrar is on the bus, so no other test builds it) and the settings window
    // build on this Qt: an error in either leaves the menu bar without File, Edit and View, and Ctrl+, without a window.
    function test_globalMenuAndSettingsBuild() {
        const t = make();
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/GlobalMenu.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const menu = comp.createObject(testCase, {win: t.win});
        verify(menu, "the menu bar is created");
        const titles = [];
        for (let i = 0; i < menu.menus.length; i++)
            titles.push(menu.menus[i].title);
        compare(titles, ["File", "Edit", "View"]);
        menu.destroy();
        t.win.openSettings();
        verify(t.win.settingsWindow, "the settings window is created");
        tryVerify(() => t.win.settingsWindow.visible);
        // What the AUR would be sent is read before it is turned on; while it is on, the closing line says what leaves.
        const sw = t.win.settingsWindow;
        const shown = text => find(sw.contentItem, i => i.text === text && i.visible) !== null;
        verify(shown("From the AUR (aur.archlinux.org), while it is on: what you search for after Return, the pages you open, "
                     + "the names of the packages installed from outside the repositories, and a build script when you ask to see it."));
        verify(shown("Nothing on a metered connection unless you choose Refresh. What you search for stays on this computer."));
        t.backend.sources = {aur: true, flathub: false, flatpak: false, screenshots: true};
        verify(shown("Nothing on a metered connection unless you choose Refresh, press Return in the search field or open an AUR page. "
                     + "What you search for stays on this computer until you press Return, which sends it to the AUR."));
        verify(!shown("Nothing on a metered connection unless you choose Refresh. What you search for stays on this computer."));
        t.win.settingsWindow.close();
    }

    // With the global menu (a registrar on the bus), its items and the window's shortcuts carry the same keys: each press
    // still acts once (Ctrl+, opens the settings window, Ctrl+2 picks the second sidebar item).
    function test_keysWithTheGlobalMenu() {
        const t = make({globalMenu: true});
        keyClick(Qt.Key_Comma, Qt.ControlModifier);
        tryVerify(() => t.win.settingsWindow && t.win.settingsWindow.visible, 2000, "Ctrl+, opened the settings window");
        t.win.settingsWindow.close();
        t.win.requestActivate();
        tryVerify(() => t.win.active, 2000);
        keyClick(Qt.Key_2, Qt.ControlModifier);
        compare(t.win.current.tab, t.win.sidebarItems[1].key);
    }

    // A key belongs to the key window alone (Files' rule): Ctrl+W typed in the settings window closes it, not the Store
    // (Qt also matches the Store window's Shortcuts and menu keys while its transient child has the keyboard), and Esc or
    // Ctrl+W typed in the Store leave the settings window open.
    function test_keysBelongToTheKeyWindow() {
        const t = make({globalMenu: true});
        keyClick(Qt.Key_Comma, Qt.ControlModifier);
        const settings = t.win.settingsWindow;
        tryVerify(() => settings && settings.visible && settings.active, 2000, "Ctrl+, opened the settings window");
        t.backend.focusWindow = settings;
        verify(t.win.childIsKey);
        keyClick(Qt.Key_W, Qt.ControlModifier);
        tryVerify(() => !settings.visible, 2000, "Ctrl+W closed the settings window");
        verify(t.win.visible, "and not the Store");

        t.win.openSettings();
        tryVerify(() => settings.visible);
        t.win.requestActivate();
        tryVerify(() => t.win.active, 2000);
        t.backend.focusWindow = t.win;
        verify(!t.win.childIsKey);
        keyClick(Qt.Key_Escape);
        keyClick(Qt.Key_F, Qt.ControlModifier);
        verify(t.win.searchField.activeFocus, "Ctrl+F works in the Store");
        verify(settings.visible, "Esc typed in the Store leaves the settings window open");
        settings.close();
    }

    // Nothing to show (no catalog in use, no app data from Arch): the page says why and offers Try Again, never a blank
    // page; with Arch's apps but no catalog, a notice says the catalog isn't available.
    function test_unavailable() {
        const t = make();
        t.backend.catalog = {inUse: false, problem: "untrusted", channel: "stable", date: "", old: false};
        t.backend.appData = {origin: "none", problem: ""};
        t.backend.sectionList = [{id: "discover", builtIn: true, blocks: []}];
        t.backend.dataChanged();
        tryVerify(() => find(t.win.page, i => i.text === "The Store Isn't Available Right Now" && i.visible) !== null);
        const reason = find(t.win.page, i => typeof i.text === "string" && i.text.indexOf("no trusted Grassfield key") >= 0);
        verify(reason && reason.visible);
        verify(reason.text.indexOf("Arch's app data isn't installed") >= 0, reason.text);
        const again = find(t.win.page, i => i.text === "Try Again" && i.visible);
        verify(again);
        const before = t.backend.calls.filter(c => c === "refresh").length;
        mouseClick(again);
        compare(t.backend.calls.filter(c => c === "refresh").length, before + 1);
        // Offline: the reason says so.
        t.backend.online = false;
        tryVerify(() => reason.text.indexOf("You're offline") === 0);
        t.backend.online = true;
        // Arch's apps without the catalog: Discover shows them, with the notice.
        t.backend.appData = {origin: "installed", problem: ""};
        t.backend.sectionList = [{id: "discover", builtIn: true, blocks: [{kind: "row", title: "Graphics", category: "graphics",
                                                                            apps: [t.backend.apps[0]]}]}];
        t.backend.dataChanged();
        tryVerify(() => find(t.win.contentItem, i => i.text === "The Grassfield catalog isn't available: Arch's apps are shown.") !== null);
        verify(!find(t.win.page, i => i.text === "The Store Isn't Available Right Now" && i.visible));
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
