import QtQuick
import QtTest
import Grassfield.Ui

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

    function test_fileMenuNoNewWindowWithoutAction() {
        // Launching the entry again is not known to open a window: no item.
        const entry = {id: "foot", actions: []};
        compare(model.fileMenu(ctx({entry: entry, singleMain: false})).length, 0);
        verify(!model.hasFileMenu(ctx({entry: entry, singleMain: true})));
        verify(!model.hasFileMenu(ctx({entry: null})));
    }

    function test_fileMenuSingleWindowAppWithOtherActionsOnly() {
        // SingleMainWindow=true with actions but no new-window action: no New Window, actions stay.
        const entry = {id: "solo", actions: [{id: "open-settings", name: "Settings"}]};
        const items = model.fileMenu(ctx({entry: entry, singleMain: true}));
        compare(items.map(i => i.text).join("|"), "Settings");
        verify(!items.some(i => i.id === "newWindow"));
    }

    function test_fileMenuNewWindowFromAction() {
        const entry = {id: "chromium", actions: [{id: "new-window", name: "New Window"}]};
        compare(ids(model.fileMenu(ctx({entry: entry}))).join(","), "newWindow");
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

    // macOS window tiling (docs/specs/tiling.md TL25), only with the plugin's "window-tiling": Fill, Center, Move & Resize (the
    // headed sections Halves, Quarters and, with "tiling-arrange", Arrange; then Return to Previous Size) and one Move to
    // <display> row per other output; disabled in full screen and for a zoomed window.
    function test_windowMenuTilingItems() {
        compare(ids(model.windowMenu(ctx({}))).indexOf("tile"), -1, "no tiling items without the capability");
        const items = model.windowMenu(ctx({canTile: true}));
        compare(ids(items).join(","), "minimize,zoom,tile,tile,moveResize,fullscreen,moveMenu,bringAll,window,window");
        compare(items.filter(i => i.id === "tile").map(i => i.place).join(","), "fill,center");
        compare(items.find(i => i.place === "fill").shortcut, "Super+Ctrl+Return");
        compare(items.find(i => i.place === "center").shortcut, "Super+Ctrl+C");
        // macOS order: Minimize, Zoom, Fill, Center, then a separator before Move & Resize and one after its section.
        compare(items.slice(0, 7).map(i => i.separator ? "-" : i.id).join(","), "minimize,zoom,tile,tile,-,moveResize,-");
        const sub = items.find(i => i.id === "moveResize").submenu.filter(i => !i.separator);
        compare(sub.map(i => i.header ? "[" + i.text + "]" : i.place).join(","),
                "[Halves],left,right,top,bottom,[Quarters],top-left,top-right,bottom-left,bottom-right,previous");
        compare(sub[1].shortcut, "Super+Ctrl+Left");
        compare(sub.find(i => i.place === "top-left").shortcut, "Super+Ctrl+U");
        compare(sub.find(i => i.place === "bottom-right").shortcut, "Super+Ctrl+K");
        compare(sub[sub.length - 1].text, "Return to Previous Size");
        verify(sub.filter(i => !i.header).every(i => i.enabled));
        verify(sub.filter(i => i.header).every(i => i.id === undefined), "a header runs nothing");
        const full = model.windowMenu(ctx({canTile: true, fullscreen: true}));
        verify(full.find(i => i.id === "moveResize").submenu.filter(i => !i.separator && !i.header).every(i => !i.enabled), "no tiling in full screen");
        verify(!full.find(i => i.place === "fill").enabled);
        const zoomed = model.windowMenu(ctx({canTile: true, maximized: true}));
        verify(!zoomed.find(i => i.place === "fill").enabled, "no tiling for a zoomed window (the plugin refuses it, R13)");
        verify(!zoomed.find(i => i.id === "moveResize").enabled);
    }

    // Each tiling row has its glyph (TL25): a place its zone alone, an arrangement its zones with the window's own first.
    function test_windowMenuTilingGlyphs() {
        const items = model.windowMenu(ctx({canTile: true, canArrange: true}));
        compare(JSON.stringify(items.find(i => i.place === "fill").glyph), JSON.stringify({zones: [[0, 0, 12, 12]], own: 0}));
        compare(JSON.stringify(items.find(i => i.place === "center").glyph.zones), JSON.stringify(Tokens.tilingGlyphCenter));
        const sub = items.find(i => i.id === "moveResize").submenu;
        compare(JSON.stringify(sub.find(i => i.place === "left").glyph.zones), JSON.stringify([Tokens.tilingLayoutLeftRight[0]]));
        compare(JSON.stringify(sub.find(i => i.place === "bottom").glyph.zones), JSON.stringify([Tokens.tilingLayoutTopBottom[1]]));
        compare(JSON.stringify(sub.find(i => i.place === "bottom-left").glyph.zones), JSON.stringify([Tokens.tilingLayoutQuarters[2]]));
        const leftRight = sub.find(i => i.layout === "left-right");
        compare(JSON.stringify(leftRight.glyph), JSON.stringify({zones: Tokens.tilingLayoutLeftRight, own: 0}));
        compare(JSON.stringify(sub.find(i => i.layout === "quarters").glyph), JSON.stringify({zones: Tokens.tilingLayoutQuarters, own: -1}), "Quarters in full");
        compare(sub.find(i => i.place === "previous").glyph, undefined, "Return to Previous Size has no glyph");
    }

    // Arrange (M27, M28): with the plugin's tiling-arrange, after Quarters; Alt shows the "& Quarters" alternates in place.
    function test_windowMenuArrangeAndItsAlternates() {
        const without = model.windowMenu(ctx({canTile: true})).find(i => i.id === "moveResize").submenu;
        verify(!without.some(i => i.id === "arrange" || (i.header && i.text === "Arrange")), "no Arrange without tiling-arrange");
        const sub = model.windowMenu(ctx({canTile: true, canArrange: true})).find(i => i.id === "moveResize").submenu.filter(i => !i.separator);
        compare(sub.map(i => i.header ? "[" + i.text + "]" : (i.place || i.layout)).join(","),
                "[Halves],left,right,top,bottom,[Quarters],top-left,top-right,bottom-left,bottom-right,[Arrange],left-right,right-left,top-bottom,bottom-top,quarters,previous");
        const arrange = sub.filter(i => i.id === "arrange");
        compare(arrange.map(i => i.text).join(","), "Left & Right,Right & Left,Top & Bottom,Bottom & Top,Quarters");
        compare(arrange.map(i => i.alternate ? i.alternate.layout : "").join(","), "left-quarters,right-quarters,top-quarters,bottom-quarters,");
        compare(arrange.map(i => i.alternate ? i.alternate.text : "").join(","), "Left & Quarters,Right & Quarters,Top & Quarters,Bottom & Quarters,");
        compare(arrange[0].shortcut, "Super+Ctrl+Shift+Left");
        compare(arrange[3].shortcut, "Super+Ctrl+Shift+Down");
        compare(arrange[0].alternate.shortcut, "Super+Ctrl+Alt+Shift+Left");
        compare(arrange[2].alternate.shortcut, "Super+Ctrl+Alt+Shift+Up");
        compare(arrange[4].shortcut, "", "Quarters has no key");
        compare(arrange[0].alternate.id, "arrange");
        compare(JSON.stringify(arrange[0].alternate.glyph.zones), JSON.stringify(Tokens.tilingLayoutLeftQuarters));
        const full = model.windowMenu(ctx({canTile: true, canArrange: true, fullscreen: true})).find(i => i.id === "moveResize").submenu;
        verify(full.filter(i => i.id === "arrange").every(i => !i.enabled && (!i.alternate || !i.alternate.enabled)));
    }

    // Move to <display> (M23, M56): one row per other output after Move & Resize, named as Settings > Displays names it.
    function test_windowMenuMoveToDisplay() {
        const outputs = [{name: "DP-1", model: "LG UltraFine", builtIn: false}, {name: "eDP-1", model: "Panel", builtIn: true}, {name: "HDMI-A-1", model: "", builtIn: false}];
        const items = model.windowMenu(ctx({canTile: true, outputs: outputs}));
        const rows = items.filter(i => i.id === "moveToOutput");
        compare(rows.map(i => i.text).join("|"), "Move to LG UltraFine|Move to Built-in Display|Move to HDMI-A-1");
        compare(rows.map(i => i.output).join(","), "DP-1,eDP-1,HDMI-A-1");
        verify(rows.every(i => i.enabled));
        const at = items.findIndex(i => i.id === "moveResize");
        compare(items[at + 1].id, "moveToOutput", "right after Move & Resize");
        verify(items[at + 4].separator);
        verify(model.windowMenu(ctx({canTile: true, outputs: outputs, fullscreen: true})).filter(i => i.id === "moveToOutput").every(i => !i.enabled));
        compare(model.windowMenu(ctx({outputs: outputs})).filter(i => i.id === "moveToOutput").length, 0, "nothing without window-tiling");
    }

    // The tiling popover (TL23, M19-M21): Move & Resize and Fill & Arrange as glyphs, Full Screen, Move to <display>.
    function test_tilingPopover() {
        const outputs = [{name: "DP-1", model: "LG UltraFine", builtIn: false}];
        const p = model.tilingPopover({alt: false, tileable: true, canArrange: true, fullscreen: false, outputs: outputs});
        compare(p.sections.map(s => s.title).join("|"), "Move & Resize|Fill & Arrange");
        compare(p.sections[0].items.map(i => i.place).join(","), "left,right,top,bottom");
        compare(p.sections[1].items.map(i => i.place || i.layout).join(","), "fill,left-right,left-quarters,quarters");
        verify(p.sections.every(s => s.items.every(i => i.enabled && i.glyph && i.glyph.zones.length > 0)));
        compare(p.rows.map(i => i.id).join(","), "fullscreen,moveToOutput");
        compare(p.rows[0].text, "Full Screen");
        compare(p.rows[1].text, "Move to LG UltraFine");
        compare(p.rows[1].output, "DP-1");
        // Alt (M20): the quarters, Center, Right & Left, Right & Quarters; Quarters and Full Screen unchanged.
        const alt = model.tilingPopover({alt: true, tileable: true, canArrange: true, fullscreen: false, outputs: []});
        compare(alt.sections[0].items.map(i => i.place).join(","), "top-left,top-right,bottom-left,bottom-right");
        compare(alt.sections[1].items.map(i => i.place || i.layout).join(","), "center,right-left,right-quarters,quarters");
        compare(alt.rows.map(i => i.id).join(","), "fullscreen");
    }

    function test_tilingPopoverGreysWhatTheWindowCannotDo() {
        const outputs = [{name: "DP-1", model: "", builtIn: false}];
        const no = model.tilingPopover({alt: false, tileable: false, canArrange: true, fullscreen: false, outputs: outputs});
        verify(no.sections.every(s => s.items.every(i => !i.enabled)), "a window that cannot be tiled: every glyph greyed (TL9)");
        verify(no.rows[0].enabled, "Full Screen stays");
        verify(!no.rows[1].enabled);
        const noArrange = model.tilingPopover({alt: false, tileable: true, canArrange: false, fullscreen: false, outputs: []});
        compare(noArrange.sections[1].items.map(i => i.enabled).join(","), "true,false,false,false", "arrangements need tiling-arrange");
        verify(noArrange.sections[0].items.every(i => i.enabled));
        // Full screen (M21): Exit Full Screen only.
        const full = model.tilingPopover({alt: false, tileable: true, canArrange: true, fullscreen: true, outputs: outputs});
        compare(full.sections.length, 0);
        compare(full.rows.map(i => i.id + ":" + i.text).join(","), "fullscreen:Exit Full Screen");
    }

    function test_windowCommandsAreGreyWhenTheAppIsNamedFromStagesOnly() {
        const items = model.windowMenu(ctx({displayOnly: true}));
        for (const id of ["minimize", "zoom", "fullscreen", "moveMenu"])
            verify(!items.find(i => i.id === id).enabled, id);
        verify(items.find(i => i.id === "bringAll").enabled);
        verify(model.windowMenu(ctx({})).find(i => i.id === "minimize").enabled);
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
