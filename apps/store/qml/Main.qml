pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store
import "StoreNav.js" as StoreNav

// Grassfield Store (ADR-0037, spec SR1-SR12, SR23, SR24): the sidebar (search, Discover, the catalog's sections, Categories,
// Updates, the local user's row for Installed) and the page on the right, with Back and Forward in the toolbar. App windows
// are opaque (master-prompt 5.5). Step 2 reads only: no app is installed, removed or opened from here yet.
Window {
    id: root

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu
    // --page: the page to open first (discover, section:<id>, categories, category:<id>, app:<id>, search:<words>,
    // installed, updates).
    property string startPage: ""
    // ADR-0015: this window draws its own chrome (the lights over the sidebar, the toolbar over the page).
    property string gfChromeRole: "store"
    readonly property alias searchField: sidebar.search
    // The page shown and its kind (section, categories, category, app, search, installed, updates); the tests read them.
    readonly property alias page: pageLoader.item
    readonly property alias pageKind: pageLoader.page

    title: qsTr("Grassfield Store")
    width: Tokens.storeWindowWidth
    height: Tokens.storeWindowHeight
    minimumWidth: Tokens.storeWindowMinWidth
    minimumHeight: Tokens.storeWindowMinHeight
    visible: true
    color: Appearance.colors.windowBackground

    // ---- Data, read again at each new snapshot (StoreBackend::dataChanged).
    property var sections: []
    property var categories: []

    readonly property var sidebarItems: root.sections.map(s => ({
                key: "section:" + s.id,
                page: "section",
                id: s.id,
                title: s.builtIn ? qsTr("Discover") : s.title,
                icon: Store.symbolIcon(s.symbol)
            })).concat([{key: "categories", page: "categories", id: "", title: qsTr("Categories"), icon: "grid"},
                {key: "updates", page: "updates", id: "", title: qsTr("Updates"), icon: "arrow-down-circle"}])

    function reload(): void {
        root.sections = root.backend.sections();
        root.categories = root.backend.categories();
        root.showPage(true);
        // --page waits for the first data: a section's row exists only then.
        if (root.waitingPage !== "" && root.backend.revision > 0) {
            const page = root.waitingPage;
            root.waitingPage = "";
            root.openPage(page);
        }
    }

    property string waitingPage: ""

    Connections {
        target: root.backend
        function onDataChanged(): void {
            root.reload();
        }
    }

    // ---- Navigation (StoreNav.js): pages with their scroll, the sidebar row each belongs to.
    property var nav: StoreNav.start({page: "section", id: "discover", tab: "section:discover"})
    readonly property bool canBack: StoreNav.canBack(root.nav)
    readonly property bool canForward: StoreNav.canForward(root.nav)
    // Read in handlers through root.nav.current: a handler of navChanged may run before this binding is updated.
    readonly property var current: root.nav.current

    function currentScroll(): real {
        return (pageLoader.item as ScrollPage)?.scroll ?? 0;
    }

    function visit(entry: var): void {
        root.nav = StoreNav.visit(root.nav, entry, root.currentScroll());
    }

    function pick(key: string): void {
        const item = root.sidebarItems.find(i => i.key === key);
        if (!item)
            return;
        sidebar.search.text = "";
        root.visit({page: item.page, id: item.id, tab: key});
    }

    function openApp(id: string): void {
        root.visit({page: "app", id: id, tab: root.nav.current.tab});
    }

    function openCategory(id: string): void {
        sidebar.search.text = "";
        root.visit({page: "category", id: id, tab: "categories"});
    }

    function openInstalled(): void {
        sidebar.search.text = "";
        root.visit({page: "installed", id: "", tab: ""});
    }

    function goBack(): void {
        root.nav = StoreNav.back(root.nav, root.currentScroll());
        root.syncSearchField();
    }

    function goForward(): void {
        root.nav = StoreNav.forward(root.nav, root.currentScroll());
        root.syncSearchField();
    }

    // The field shows the query of a search page and is empty elsewhere.
    function syncSearchField(): void {
        sidebar.search.text = root.nav.current.page === "search" ? root.nav.current.query : "";
    }

    // Typing searches at once (SR6): the first key opens the results page, the next ones change it in place; clearing the
    // field goes back to the page before it.
    function search(text: string): void {
        if (text.trim() === "") {
            if (root.nav.current.page === "search")
                root.goBack();
            return;
        }
        const entry = {page: "search", id: "", query: text, tab: root.nav.current.tab};
        root.nav = root.nav.current.page === "search" ? StoreNav.replace(root.nav, entry) : StoreNav.visit(root.nav, entry, root.currentScroll());
    }

    function focusSearch(): void {
        sidebar.search.forceActiveFocus(Qt.ShortcutFocusReason);
        sidebar.search.selectAll();
    }

    onNavChanged: root.showPage(false)

    // The page of `current`: a search page that only changes its query keeps its item; anything else is made again, and gets
    // back the scroll it was left at. `again`: the same page with new data (a new snapshot), its scroll kept.
    function showPage(again: bool): void {
        const c = root.nav.current;
        if (!again && c.page === "search" && pageLoader.item && pageLoader.page === "search") {
            const results = pageLoader.item as SearchPage;
            results.query = c.query;
            results.results = root.backend.search(c.query);
            return;
        }
        const scroll = again ? root.currentScroll() : (c.scroll || 0);
        pageLoader.page = c.page;
        // The page reads this copy, not `current`: a page being replaced never sees the next page's entry.
        pageLoader.entry = c;
        pageLoader.sourceComponent = null;
        pageLoader.sourceComponent = c.page === "section" ? sectionPage : c.page === "categories" ? categoriesPage
            : c.page === "category" ? categoryPage : c.page === "app" ? productPage : c.page === "search" ? searchPage
            : c.page === "installed" ? installedPage : c.page === "updates" ? updatesPage : null;
        if (pageLoader.item && scroll > 0)
            (pageLoader.item as ScrollPage).restoreScroll(scroll);
    }

    function openPage(page: string): void {
        const colon = page.indexOf(":");
        const kind = colon < 0 ? page : page.substring(0, colon);
        const arg = colon < 0 ? "" : page.substring(colon + 1);
        if (kind === "section" || kind === "categories" || kind === "updates")
            root.pick(kind === "section" ? "section:" + arg : kind);
        else if (kind === "category")
            root.openCategory(arg);
        else if (kind === "app")
            root.openApp(arg);
        else if (kind === "installed")
            root.openInstalled();
        else if (kind === "search") {
            sidebar.search.text = arg;
            root.search(arg);
        }
    }

    Component.onCompleted: {
        root.waitingPage = root.startPage;
        root.reload();
    }

    // ---- Settings window (Ctrl+,).
    property var settingsWindow: null

    function openSettings(): void {
        if (!root.settingsWindow)
            root.settingsWindow = settingsComponent.createObject(root, {backend: root.backend, transientParent: root});
        root.settingsWindow.show();
        root.settingsWindow.raise();
        root.settingsWindow.requestActivate();
    }

    Component {
        id: settingsComponent
        SettingsWindow {}
    }

    // ---- Appearance (grassfield.json, read by the backend) and the window's own surface.
    Binding {
        target: Appearance
        property: "windowSurface"
        value: true
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: 0
    }

    Binding {
        target: Appearance
        property: "dark"
        value: root.backend.dark
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: root.backend.reduceMotion
    }

    Binding {
        target: Appearance
        property: "increaseContrast"
        value: root.backend.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: root.backend.textScale
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: root.backend.accentColor
    }

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: root.backend.accentHighlight
    }

    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: root.backend.shortcutStyle
    }

    // ---- Keyboard (spec "Keyboard"). The global menu's items carry the same shortcuts; each acts once.
    Loader {
        active: root.globalMenu
        sourceComponent: GlobalMenu {
            win: root
        }
    }

    component Key: Shortcut {
        property var run: null
        onActivated: run()
        onActivatedAmbiguously: run()
    }

    Key {
        sequence: "Ctrl+F"
        run: root.focusSearch
    }
    Key {
        sequence: "Ctrl+R"
        run: () => root.backend.refresh()
    }
    Key {
        sequences: ["Ctrl+[", "Alt+Left"]
        run: root.goBack
    }
    Key {
        sequences: ["Ctrl+]", "Alt+Right"]
        run: root.goForward
    }
    Key {
        sequence: "Ctrl+,"
        run: root.openSettings
    }
    Key {
        sequence: "Ctrl+W"
        run: () => root.close()
    }
    Key {
        sequence: "Ctrl+Q"
        run: () => Qt.quit()
    }

    // Ctrl+1 … Ctrl+9: the sidebar's items in order.
    Repeater {
        model: 9

        delegate: Item {
            id: digit
            required property int index

            Shortcut {
                sequence: "Ctrl+" + (digit.index + 1)
                enabled: digit.index < root.sidebarItems.length
                onActivated: root.pick(root.sidebarItems[digit.index].key)
                onActivatedAmbiguously: root.pick(root.sidebarItems[digit.index].key)
            }
        }
    }

    // ---- Layout.
    Sidebar {
        id: sidebar
        height: parent.height
        win: root
        items: root.sidebarItems
        selectedKey: root.current.tab || ""
        user: root.backend.user
        installedShown: root.current.page === "installed"
        onPicked: key => root.pick(key)
        onAccountPicked: root.openInstalled()
        onQueryEdited: text => root.search(text)
        onQueryAccepted: {
            if (pageLoader.page === "search" && pageLoader.item)
                (pageLoader.item as SearchPage).focusFirst();
        }
    }

    Item {
        id: detail
        x: sidebar.width
        width: parent.width - sidebar.width
        height: parent.height

        Loader {
            id: pageLoader
            property string page: ""
            property var entry: ({})
            anchors.fill: parent
            focus: true
        }

        Text {
            anchors.centerIn: parent
            visible: root.backend.loading && root.sections.length === 0
            textFormat: Text.PlainText
            text: qsTr("Loading apps…")
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBodySize
        }

        // Offline, or a catalog older than 30 days (SR29): one line at the bottom of the page.
        NoticeBar {
            width: Math.min(implicitWidth, parent.width - 2 * Tokens.storeContentMargin)
            x: Math.round((parent.width - width) / 2)
            y: parent.height - height - Tokens.storeNoticeBottom
            text: {
                const c = root.backend.catalog;
                if (!root.backend.online)
                    return c.inUse ? qsTr("You're offline. The catalog is from %1.").arg(c.date) : qsTr("You're offline.");
                if (c.inUse && c.old)
                    return qsTr("The catalog is from %1 and may be out of date.").arg(c.date);
                return "";
            }
        }

        UnifiedToolbar {
            id: toolbar
            width: parent.width
            window: root
            showControls: false
            showTitle: false
            canMinimize: root.backend.canMinimize
            doubleClickAction: root.backend.titlebarDoubleClick

            // Back and forward: one glass capsule with a hairline between them (macOS 27), shown once there is somewhere to go.
            leading: RimmedCapsule {
                visible: root.canBack || root.canForward
                width: navRow.width + Tokens.spacingXs
                height: Tokens.filesToolbarCapsule
                fillOpacity: Tokens.settingsToolbarFillOpacity
                Accessible.role: Accessible.Grouping
                Accessible.name: qsTr("Navigation")

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.hairline
                    height: Tokens.settingsToolbarDividerHeight
                    color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.settingsToolbarDividerOpacity)
                }

                Row {
                    id: navRow
                    anchors.centerIn: parent

                    ToolButton {
                        capsule: true
                        buttonSize: Tokens.filesToolbarGroupButton
                        iconName: "chevron-right"
                        iconRotation: 180
                        enabled: root.canBack
                        accessibleName: qsTr("Back")
                        onClicked: root.goBack()
                    }

                    ToolButton {
                        capsule: true
                        buttonSize: Tokens.filesToolbarGroupButton
                        iconName: "chevron-right"
                        enabled: root.canForward
                        accessibleName: qsTr("Forward")
                        onClicked: root.goForward()
                    }
                }
            }

            // Without a global menu bar (no registrar), the way to the settings that File > Settings… gives.
            trailing: ToolButton {
                visible: !root.globalMenu
                iconName: "gear"
                accessibleName: qsTr("Store Settings")
                onClicked: root.openSettings()
            }
        }
    }

    // ---- The pages.
    Component {
        id: sectionPage
        SectionPage {
            section: root.sections.find(s => s.id === pageLoader.entry.id) || root.sections[0] || ({id: "discover", builtIn: true, blocks: []})
            onOpened: id => root.openApp(id)
            onCategoryRequested: id => root.openCategory(id)
        }
    }

    Component {
        id: categoriesPage
        CategoriesPage {
            categories: root.categories
            onCategoryRequested: id => root.openCategory(id)
        }
    }

    Component {
        id: categoryPage
        CategoryPage {
            categoryTitle: (root.categories.find(c => c.id === pageLoader.entry.id) || {title: ""}).title
            apps: root.backend.categoryApps(pageLoader.entry.id)
            kind: pageLoader.entry.kind || ""
            onOpened: id => root.openApp(id)
            onKindPicked: kind => root.nav = StoreNav.replace(root.nav, Object.assign({}, root.current, {kind: kind}))
        }
    }

    Component {
        id: productPage
        ProductPage {
            backend: root.backend
            app: root.backend.app(pageLoader.entry.id)
            onLinkRequested: url => root.backend.openLink(url)
        }
    }

    Component {
        id: searchPage
        SearchPage {
            query: pageLoader.entry.query || ""
            results: root.backend.search(pageLoader.entry.query || "")
            onOpened: id => root.openApp(id)
        }
    }

    Component {
        id: installedPage
        InstalledPage {
            groups: root.backend.installed()
            onOpened: id => root.openApp(id)
        }
    }

    Component {
        id: updatesPage
        UpdatesPage {
            updates: root.backend.updates()
            onOpened: id => root.openApp(id)
        }
    }
}
