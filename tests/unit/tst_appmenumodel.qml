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

    // A window of fixed size (minimum = maximum: About This Computer, ADR-0040 step 1b; nested pass of 85c2c10, scenario 6):
    // its zoom light is disabled, and the Window menu greys Zoom, Enter Full Screen, Full Screen Tile and the tiling items.
    function test_windowMenuFixedSize() {
        const items = model.windowMenu(ctx({canTile: true, canArrange: true, canSplit: true, fixedSize: true,
                                            outputs: [{name: "DP-1", label: "DELL", current: true}, {name: "HDMI-A-1", label: "LG", current: false}]}));
        verify(items.find(i => i.id === "minimize").enabled, "it still minimizes");
        verify(!items.find(i => i.id === "zoom").enabled);
        verify(!items.find(i => i.id === "fullscreen").enabled);
        verify(!items.find(i => i.id === "fullScreenTile").enabled);
        verify(items.filter(i => i.id === "tile" || i.id === "moveToOutput").every(i => !i.enabled));
        verify(items.find(i => i.id === "moveToOutput") !== undefined, "Move to <display> is there, greyed");
        const sub = items.find(i => i.id === "moveResize");
        verify(!sub.enabled);
        verify(sub.submenu.filter(i => !i.separator && !i.header).every(i => !i.enabled && (!i.alternate || !i.alternate.enabled)));
        verify(items.find(i => i.id === "moveMenu").enabled, "it still moves to another Desktop");
        // Brought back by a key or a rule: Unzoom and Exit Full Screen stay.
        verify(model.windowMenu(ctx({canTile: true, fixedSize: true, maximized: true})).find(i => i.id === "zoom").enabled);
        verify(model.windowMenu(ctx({canTile: true, fixedSize: true, fullscreen: true})).find(i => i.id === "fullscreen").enabled);
        // Not of fixed size: as before.
        const free = model.windowMenu(ctx({canTile: true, fixedSize: false}));
        verify(free.find(i => i.id === "zoom").enabled && free.find(i => i.id === "fullscreen").enabled && free.find(i => i.place === "fill").enabled);
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
        compare(full.layouts.length, 0, "no Layouts section in full screen");
    }

    // The Layouts section (TL27, T1a, T1f): the catalogue of the window's output class, after Fill & Arrange, with tiling-layouts.
    function test_tilingPopoverLayoutsFollowTheOutputClass() {
        const p = cls => model.tilingPopover({alt: false, tileable: true, canArrange: true, canLayouts: true, outputClass: cls, fullscreen: false, outputs: []});
        compare(p("small").layouts.map(l => l.id).join(","), "left-right,wide-left,left-quarters,quarters");
        compare(p("large").layouts.map(l => l.id).join(","), "left-right,wide-left,left-quarters,quarters,thirds,wide-center");
        compare(p("ultrawide").layouts.map(l => l.id).join(","), "left-right,wide-left,left-quarters,quarters,thirds,wide-center,four-columns");
        compare(p("portrait").layouts.map(l => l.id).join(","), "top-bottom,stacked-thirds,top-quarters");
        compare(p("unknown").layouts.length, 0);
        const large = p("large").layouts;
        verify(large.every(l => l.enabled && l.text !== "" && Array.isArray(l.zones) && l.zones.length >= 2), "names and zones from the tiling.layout* tokens");
        compare(large[4].zones.length, 3, "thirds");
        compare(large[4].text, "Thirds");
        compare(JSON.stringify(large[4].zones), JSON.stringify(Tokens.tilingLayoutThirds));
        // Greyed for a window that cannot be tiled; absent without the plugin's tiling-layouts.
        verify(model.tilingPopover({alt: false, tileable: false, canArrange: true, canLayouts: true, outputClass: "small", fullscreen: false, outputs: []}).layouts.every(l => !l.enabled));
        compare(model.tilingPopover({alt: false, tileable: true, canArrange: true, outputClass: "small", fullscreen: false, outputs: []}).layouts.length, 0);
        // Alt changes the glyph sections, not the Layouts section.
        compare(model.tilingPopover({alt: true, tileable: true, canArrange: true, canLayouts: true, outputClass: "small", fullscreen: false, outputs: []}).layouts.length, 4);
    }

    // ADR-0036 D69 (capture defect: Quarters at 1440 x 900 with Settings): the popover greys, never hides, the places, the
    // arrangements and the Layouts zones the window does not fit; Fill and Center stay; a layout none of whose zones fits is
    // greyed whole.
    function test_tilingPopoverGreysWhatTheWindowDoesNotFit() {
        const fit = {zones: ["0,0,6,6", "6,0,6,6", "0,6,6,6", "6,6,6,6", "0,0,12,6", "0,6,12,6"], places: ["top-left", "top-right", "bottom-left", "bottom-right", "top", "bottom"]};
        const p = alt => model.tilingPopover({alt: alt, tileable: true, canArrange: true, canLayouts: true, outputClass: "small", fullscreen: false, outputs: [], fit: fit});
        const plain = p(false);
        compare(plain.sections[0].items.map(i => i.place + ":" + i.enabled).join(","), "left:true,right:true,top:false,bottom:false", "the halves it does not fit greyed");
        compare(plain.sections[1].items.map(i => (i.place || i.layout) + ":" + i.enabled).join(","), "fill:true,left-right:true,left-quarters:true,quarters:false",
                "Quarters greyed: its first zone, the window's own, is a quarter; Left & Quarters keeps the half for it");
        const alt = p(true);
        verify(alt.sections[0].items.every(i => !i.enabled), "every quarter greyed, still shown");
        compare(alt.sections[0].items.length, 4);
        verify(alt.sections[1].items[0].enabled, "Center stays");
        const layouts = plain.layouts;
        compare(layouts.map(l => l.id + ":" + l.enabled + ":" + l.disabledZones.join("+")).join(","), "left-right:true:,wide-left:true:,left-quarters:true:1+2,quarters:false:0+1+2+3",
                "the zones it does not fit; a layout with none it fits greyed whole");
        // Nothing known (an older plugin): nothing greyed.
        const free = model.tilingPopover({alt: false, tileable: true, canArrange: true, canLayouts: true, outputClass: "small", fullscreen: false, outputs: []});
        verify(free.sections.every(s => s.items.every(i => i.enabled)));
        verify(free.layouts.every(l => l.enabled && l.disabledZones.length === 0));
    }

    // D69: the Window menu greys the Halves, Quarters and Arrange items the window does not fit, with their keys (the plugin
    // refuses those keys); a place beside a neighbour (the places list) apart from its zone (an arrangement's).
    function test_windowMenuGreysWhatTheWindowDoesNotFit() {
        const fit = {zones: ["0,0,6,6", "6,0,6,6", "0,6,6,6", "6,6,6,6"], places: ["top-left", "top-right", "bottom-left", "bottom-right", "left"]};
        const items = model.windowMenu(ctx({canTile: true, canArrange: true, fit: fit}));
        const sub = items.find(i => i.id === "moveResize").submenu;
        const state = place => sub.find(i => i.place === place).enabled;
        verify(!state("left"), "Left beside a neighbour does not fit");
        verify(state("right") && state("top") && state("bottom"));
        verify(["top-left", "top-right", "bottom-left", "bottom-right"].every(q => !state(q)), "the quarters greyed, still listed");
        const arrange = layout => sub.find(i => i.layout === layout);
        verify(arrange("left-right").enabled, "Left & Right: its half zone fits");
        verify(!arrange("quarters").enabled, "Quarters greyed");
        verify(arrange("left-right").alternate.enabled, "Left & Quarters keeps the half for the window");
        verify(arrange("top-bottom").enabled);
        verify(items.find(i => i.id === "tile" && i.place === "fill").enabled, "Fill stays");
        verify(items.find(i => i.id === "tile" && i.place === "center").enabled, "Center stays");
        compare(arrange("quarters").shortcut, model.windowMenu(ctx({canTile: true, canArrange: true})).find(i => i.id === "moveResize").submenu.find(i => i.layout === "quarters").shortcut,
                "a greyed item keeps its key shown");
    }

    // TL33 (step 6a): with the plugin's tiling-split the Full Screen row is the submenu Entire Screen, Left of Screen, Right of
    // Screen; the halves greyed for a window that cannot be tiled now; on a Split View Desktop only Exit Full Screen, which
    // sends the window back (exitSplit).
    function test_tilingPopoverFullScreenSubmenu() {
        const outputs = [{name: "DP-1", model: "LG UltraFine", builtIn: false}];
        const p = model.tilingPopover({alt: false, tileable: true, canArrange: true, canSplit: true, fullscreen: false, outputs: outputs});
        compare(p.rows.map(i => i.id).join(","), "fullScreenMenu,moveToOutput");
        const row = p.rows[0];
        compare(row.text, "Full Screen");
        verify(row.enabled);
        compare(row.submenu.map(i => i.id + ":" + (i.side || "") + ":" + i.text).join("|"), "fullscreen::Entire Screen|split:left:Left of Screen|split:right:Right of Screen");
        verify(row.submenu.every(i => i.enabled));
        compare(JSON.stringify(row.submenu[0].glyph), JSON.stringify(model.placeGlyph("fill")), "Entire Screen: the whole output");
        compare(JSON.stringify(row.submenu[1].glyph.zones), JSON.stringify(Tokens.tilingLayoutLeftRight));
        compare(row.submenu[1].glyph.own, 0, "Left of Screen: the left half the window's own");
        compare(row.submenu[2].glyph.own, 1);
        // Alt changes the glyph sections, not the Full Screen submenu.
        const alt = model.tilingPopover({alt: true, tileable: true, canArrange: true, canSplit: true, fullscreen: false, outputs: []});
        compare(alt.rows.map(i => i.id).join(","), "fullScreenMenu");
        // A window that cannot be tiled now: the halves greyed, Entire Screen stays.
        const no = model.tilingPopover({alt: false, tileable: false, canArrange: true, canSplit: true, fullscreen: false, outputs: []});
        compare(no.rows[0].submenu.map(i => i.enabled).join(","), "true,false,false");
        verify(no.rows[0].enabled);
        // D47: while Stages shows its strip the plugin refuses the halves: greyed, Entire Screen stays.
        const staged = model.tilingPopover({alt: false, tileable: true, canArrange: true, canSplit: true, splitBlocked: true, fullscreen: false, outputs: []});
        compare(staged.rows[0].submenu.map(i => i.enabled).join(","), "true,false,false");
        verify(staged.sections.every(s => s.items.every(i => i.enabled)), "only the halves");
        // #48 nested pass, MAJOR C (TL8): a window wider or taller than half of its output: the halves greyed, Entire Screen and
        // the glyphs stay; a ctx that does not say (undefined) changes nothing.
        const wide = model.tilingPopover({alt: false, tileable: true, canArrange: true, canSplit: true, splittable: false, fullscreen: false, outputs: []});
        compare(wide.rows[0].submenu.map(i => i.enabled).join(","), "true,false,false");
        verify(wide.sections.every(s => s.items.every(i => i.enabled)), "only the halves");
        const fits = model.tilingPopover({alt: false, tileable: true, canArrange: true, canSplit: true, splittable: true, fullscreen: false, outputs: []});
        compare(fits.rows[0].submenu.map(i => i.enabled).join(","), "true,true,true");
        // Without tiling-split: the plain row that enters full screen.
        const plain = model.tilingPopover({alt: false, tileable: true, canArrange: true, fullscreen: false, outputs: []});
        compare(plain.rows[0].id, "fullscreen");
        compare(plain.rows[0].submenu, undefined);
        // On a Split View Desktop: Exit Full Screen only, which unsplits (not Hyprland's full screen).
        const split = model.tilingPopover({alt: false, tileable: true, canArrange: true, canSplit: true, fullscreen: false, inSplit: true, outputs: outputs});
        compare(split.sections.length, 0);
        compare(split.layouts.length, 0);
        compare(split.rows.map(i => i.id + ":" + i.text).join(","), "exitSplit:Exit Full Screen");
        verify(split.rows[0].enabled);
    }

    // TL33 (step 6a, M29): the Window menu's Full Screen Tile › Left of Screen, Right of Screen after Enter Full Screen, with the
    // plugin's tiling-split; greyed where the tiling items are (full screen, zoomed). On a Split View Desktop: Exit Full Screen
    // (exitSplit), no Zoom, no tiling item, no Full Screen Tile.
    function test_windowMenuFullScreenTile() {
        compare(ids(model.windowMenu(ctx({canTile: true}))).indexOf("fullScreenTile"), -1, "no Full Screen Tile without tiling-split");
        const items = model.windowMenu(ctx({canTile: true, canSplit: true}));
        const all = ids(items);
        compare(all.indexOf("fullScreenTile"), all.indexOf("fullscreen") + 1, "right after Enter Full Screen");
        const tile = items.find(i => i.id === "fullScreenTile");
        compare(tile.text, "Full Screen Tile");
        verify(tile.enabled);
        compare(tile.submenu.map(i => i.id + ":" + i.side + ":" + i.text).join("|"), "split:left:Left of Screen|split:right:Right of Screen");
        verify(tile.submenu.every(i => i.enabled));
        for (const over of [{fullscreen: true}, {maximized: true}, {focusedWindow: null}, {splitBlocked: true}]) {
            const t = model.windowMenu(ctx(Object.assign({canTile: true, canSplit: true}, over))).find(i => i.id === "fullScreenTile");
            verify(!t.enabled && t.submenu.every(i => !i.enabled), JSON.stringify(over));
        }
        verify(model.windowMenu(ctx({canTile: true, canSplit: true, splitBlocked: true})).find(i => i.place === "fill").enabled, "D47 greys the halves only");
        // D57: a window that does not fit half of its output: Full Screen Tile greyed, the tiling items and Enter Full Screen stay.
        const wide = model.windowMenu(ctx({canTile: true, canSplit: true, splittable: false}));
        const wideTile = wide.find(i => i.id === "fullScreenTile");
        verify(!wideTile.enabled && wideTile.submenu.every(i => !i.enabled), "Full Screen Tile greyed");
        verify(wide.find(i => i.place === "fill").enabled, "Fill stays");
        verify(wide.find(i => i.id === "fullscreen").enabled, "Enter Full Screen stays");
        const split = model.windowMenu(ctx({canTile: true, canSplit: true, inSplit: true}));
        compare(ids(split).join(","), "minimize,zoom,tile,tile,moveResize,exitSplit,moveMenu,bringAll,window,window");
        compare(split.find(i => i.id === "exitSplit").text, "Exit Full Screen");
        verify(split.find(i => i.id === "exitSplit").enabled);
        verify(!split.find(i => i.id === "zoom").enabled, "no Zoom on a Split View Desktop");
        verify(!split.find(i => i.place === "fill").enabled, "the Desktop places its windows");
        verify(!split.find(i => i.id === "moveResize").enabled);
        verify(!split.find(i => i.id === "minimize").enabled, "D56: not minimized, as in full screen");
        verify(model.windowMenu(ctx({canTile: true, canSplit: true})).find(i => i.id === "minimize").enabled, "elsewhere Minimize stays");
        verify(!model.windowMenu(ctx({canTile: true, fullscreen: true})).find(i => i.id === "minimize").enabled, "D61: not minimized in full screen either");
        verify(!model.windowMenu(ctx({canTile: true, canSplit: true, inSplit: true, focusedWindow: null})).find(i => i.id === "exitSplit").enabled);
    }

    // Step 6d (ADR-0036 D71): with the plugin's tiling-split-rows, a Split View window's popover offers the macOS rows, and the
    // Window menu adds Make Window Full Screen and Replace Tiled Window after Exit Full Screen; Replace only while the other half
    // holds a window. Without the feature, Exit Full Screen alone as before.
    function test_splitViewRows() {
        const pop = c => model.tilingPopover(Object.assign({alt: false, tileable: true, canArrange: true, canSplit: true, fullscreen: false, inSplit: true, outputs: []}, c));
        const rows = pop({canSplitRows: true, splitPair: true}).rows;
        compare(rows.map(i => i.id + ":" + i.text).join(","), "exitSplit:Move Window to Desktop,splitFullscreen:Make Window Full Screen,splitReplace:Replace Tiled Window");
        verify(rows.every(i => i.enabled), "two windows: every row");
        const lone = pop({canSplitRows: true, splitPair: false}).rows;
        compare(lone.map(i => i.enabled).join(","), "true,true,false", "one window: nothing to keep, Replace greyed");
        compare(pop({canSplitRows: false, splitPair: true}).rows.map(i => i.id + ":" + i.text).join(","), "exitSplit:Exit Full Screen", "without the feature: as before");
        compare(pop({canSplitRows: true, splitPair: true, inSplit: false, fullscreen: true}).rows.map(i => i.id).join(","), "fullscreen", "in full screen: Exit Full Screen only");
        verify(pop({canSplitRows: true, splitPair: true}).rows.every(i => i.glyph && i.glyph.own === -1 && i.glyph.zones.length === 0), "rows without a glyph");
        const menu = model.windowMenu(ctx({canTile: true, canSplit: true, inSplit: true, canSplitRows: true, splitPair: true}));
        const all = ids(menu);
        compare(all.slice(all.indexOf("exitSplit"), all.indexOf("exitSplit") + 3).join(","), "exitSplit,splitFullscreen,splitReplace");
        compare(menu.find(i => i.id === "splitFullscreen").text, "Make Window Full Screen");
        compare(menu.find(i => i.id === "splitReplace").text, "Replace Tiled Window");
        verify(menu.find(i => i.id === "splitFullscreen").enabled && menu.find(i => i.id === "splitReplace").enabled);
        verify(!model.windowMenu(ctx({canTile: true, canSplit: true, inSplit: true, canSplitRows: true, splitPair: false})).find(i => i.id === "splitReplace").enabled, "one window: Replace greyed");
        const away = model.windowMenu(ctx({canTile: true, canSplit: true, inSplit: true, canSplitRows: true, splitPair: true, focusedWindow: null}));
        verify(!away.find(i => i.id === "splitFullscreen").enabled && !away.find(i => i.id === "splitReplace").enabled, "no window: greyed");
        compare(ids(model.windowMenu(ctx({canTile: true, canSplit: true, inSplit: true, splitPair: true}))).indexOf("splitReplace"), -1, "without the feature: no rows");
        compare(ids(model.windowMenu(ctx({canTile: true, canSplit: true, canSplitRows: true, splitPair: true}))).indexOf("splitFullscreen"), -1, "not on a Split View Desktop: no rows");
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

    // ADR-0036 D78: Zoom is Fill, so a filled window says Unzoom too, of fixed size or not.
    function test_windowMenuSaysUnzoomForAFilledWindow() {
        compare(model.windowMenu(ctx({filled: true})).find(i => i.id === "zoom").text, "Unzoom");
        compare(model.windowMenu(ctx({filled: false})).find(i => i.id === "zoom").text, "Zoom");
        compare(model.windowMenu(ctx({})).find(i => i.id === "zoom").text, "Zoom", "an older shell context has no filled");
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
