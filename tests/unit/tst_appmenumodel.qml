import QtQuick
import QtTest

// Application menu models (shell/menubar/model/AppMenuModel.qml): real items only.
TestCase {
    id: testCase
    name: "AppMenuModel"

    property var model: null

    function initTestCase() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../shell/menubar/model/AppMenuModel.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        model = comp.createObject(testCase);
    }

    function ctx(over) {
        const base = {
            hasApp: true,
            appName: "Chromium",
            entry: {id: "chromium", actions: [{id: "new-window", name: "New Window"}, {id: "new-private-window", name: "New Incognito Window"}]},
            singleMain: false,
            windows: [{ref: "w1", title: "Docs", focused: true, minimized: false}, {ref: "w2", title: "Mail", focused: false, minimized: true}],
            focusedWindow: "w1",
            fullscreen: false,
            maximized: false,
            windowSpaceId: 1,
            othersCount: 2,
            hiddenCount: 0,
            spaces: [{id: 1}, {id: 2}],
            newSpaceId: 3
        };
        return Object.assign(base, over);
    }

    function ids(items) {
        return items.filter(i => !i.separator).map(i => i.id);
    }

    function test_appMenuItems() {
        const items = model.appMenu(ctx({}));
        compare(ids(items).join(","), "about,hide,hideOthers,showAll,quit");
        compare(items[0].text, "About Chromium");
        compare(items.find(i => i.id === "hide").text, "Hide Chromium");
        compare(items.find(i => i.id === "quit").text, "Quit Chromium");
        verify(items.find(i => i.id === "showAll").enabled === false);
    }

    function test_appMenuShowAllEnabledWhenHidden() {
        verify(model.appMenu(ctx({hiddenCount: 1})).find(i => i.id === "showAll").enabled);
        verify(!model.appMenu(ctx({othersCount: 0})).find(i => i.id === "hideOthers").enabled);
    }

    function test_appMenuWithoutAppIsDisabled() {
        const items = model.appMenu(ctx({hasApp: false, appName: "", windows: [], entry: null}));
        verify(items.filter(i => !i.separator && i.id !== "showAll").every(i => i.enabled === false));
    }

    function test_fileMenuFromDesktopActions() {
        const items = model.fileMenu(ctx({}));
        // The "new-window" action backs New Window; the other action is its own item.
        compare(items.filter(i => !i.separator).map(i => i.text).join("|"), "New Window|New Incognito Window");
        compare(items[2].id, "entryAction");
        compare(items[2].index, 1);
    }

    function test_fileMenuNewWindowWithoutActions() {
        const entry = {id: "foot", actions: []};
        compare(ids(model.fileMenu(ctx({entry: entry, singleMain: false}))).join(","), "newWindow");
    }

    function test_fileMenuEmptyForSingleWindowAppWithoutActions() {
        const entry = {id: "solo", actions: []};
        compare(model.fileMenu(ctx({entry: entry, singleMain: true})).length, 0);
        verify(!model.hasFileMenu(ctx({entry: entry, singleMain: true})));
        verify(!model.hasFileMenu(ctx({entry: null})));
    }

    function test_fileMenuSingleWindowAppWithActionsKeepsNewWindow() {
        verify(model.hasFileMenu(ctx({singleMain: true})));
    }

    function test_windowMenu() {
        const items = model.windowMenu(ctx({}));
        compare(ids(items).join(","), "minimize,zoom,fullscreen,moveMenu,bringAll,window,window");
        compare(items.find(i => i.id === "fullscreen").text, "Enter Full Screen");
        const list = items.filter(i => i.id === "window");
        compare(list[0].text, "Docs");
        verify(list[0].checked);
        compare(list[1].text, "Mail (minimized)");
        verify(!list[1].checked);
        compare(list[1].ref, "w2");
    }

    function test_windowMenuMoveToDesktopSubmenu() {
        const move = model.windowMenu(ctx({})).find(i => i.id === "moveMenu");
        const sub = move.submenu.filter(i => !i.separator);
        compare(sub.map(i => i.text).join("|"), "Desktop 1|Desktop 2|New Desktop");
        verify(sub[0].checked);
        verify(sub[0].enabled === false);
        compare(sub[1].space, 2);
        compare(sub[2].id, "moveToNew");
        compare(sub[2].space, 3);
    }

    function test_windowMenuFullscreenAndZoomLabels() {
        const items = model.windowMenu(ctx({fullscreen: true, maximized: true}));
        compare(items.find(i => i.id === "fullscreen").text, "Exit Full Screen");
        compare(items.find(i => i.id === "zoom").text, "Unzoom");
    }

    function test_windowMenuDisablesActionsWithoutFocusedWindow() {
        const items = model.windowMenu(ctx({focusedWindow: null}));
        verify(!items.find(i => i.id === "minimize").enabled);
        verify(!items.find(i => i.id === "moveMenu").enabled);
        verify(items.find(i => i.id === "bringAll").enabled);
    }

    function test_windowTitlesAreElided() {
        const long = "x".repeat(200);
        const items = model.windowMenu(ctx({windows: [{ref: "w", title: long, focused: true, minimized: false}]}));
        const text = items.find(i => i.id === "window").text;
        compare(text.length, model.titleMax);
        verify(text.endsWith("…"));
    }

    function test_emptyTitleFallsBackToAppName() {
        const items = model.windowMenu(ctx({windows: [{ref: "w", title: "", focused: true, minimized: false}]}));
        compare(items.find(i => i.id === "window").text, "Chromium");
    }

    function test_shortcutsShown() {
        const items = model.windowMenu(ctx({}));
        compare(items.find(i => i.id === "minimize").shortcut, "Super+M");
        compare(model.appMenu(ctx({})).find(i => i.id === "hide").shortcut, "Super+H");
    }
}
