import QtQml
import Grassfield.Ui

// Application menu models (T0, docs/specs/menubar.md). Pure: builds menu item arrays from a
// plain context object, so it is unit-tested without a compositor (tests/unit/tst_appmenumodel.qml).
//
// ctx: {displayOnly?: bool (app named from the Stages event, no key window: window commands disabled), hasApp, appName, entry: {id, actions: [{id, name}]} | null, singleMain: bool,
//       windows: [{ref, title, focused, minimized}], focusedWindow: ref | null,
//       fullscreen: bool, maximized: bool, windowSpaceId: int,
//       othersCount: int, hiddenCount: int, spaces: [{id}], newSpaceId: int, canTile?: bool (plugin "window-tiling"),
//       canArrange?: bool (plugin "tiling-arrange"), outputs?: [{name, model, builtIn}] (the other outputs, plugin "tile-hover"),
//       canLayouts?: bool (plugin "tiling-layouts"), outputClass?: string (WindowTiling.outputClass, the popover's Layouts section),
//       fixedSize?: bool (the window is of fixed size, the plugin's "fixed": Zoom, Enter Full Screen and tiling greyed)}
// Items: {id, text, shortcut?, glyph?, enabled?, checked?, separator?, header?, alternate?, submenu?, ...payload}; AppMenus.run()
// performs them. The tiling popover's model (tilingPopover) shares the tiling rows (docs/specs/tiling.md TL23, TL25).
QtObject {
    id: root

    // Keyboard shortcuts shown next to items. Hardcoded in one place; mirrors the bindings in
    // config/hypr/grassfield/bindings.lua (SUPER plays Command, ADR-0002). Update both together.
    readonly property var shortcuts: ({
        hide: qsTr("Super+H"),
        minimize: qsTr("Super+M"),
        zoom: qsTr("Super+Alt+F"),
        fullscreen: qsTr("Super+Ctrl+F"),
        tileLeft: qsTr("Super+Ctrl+Left"),
        tileRight: qsTr("Super+Ctrl+Right"),
        tileTop: qsTr("Super+Ctrl+Up"),
        tileBottom: qsTr("Super+Ctrl+Down"),
        tileTopLeft: qsTr("Super+Ctrl+U"),
        tileTopRight: qsTr("Super+Ctrl+I"),
        tileBottomLeft: qsTr("Super+Ctrl+J"),
        tileBottomRight: qsTr("Super+Ctrl+K"),
        tileFill: qsTr("Super+Ctrl+Return"),
        tileCenter: qsTr("Super+Ctrl+C"),
        tilePrevious: qsTr("Super+Ctrl+R"),
        arrangeLeftRight: qsTr("Super+Ctrl+Shift+Left"),
        arrangeRightLeft: qsTr("Super+Ctrl+Shift+Right"),
        arrangeTopBottom: qsTr("Super+Ctrl+Shift+Up"),
        arrangeBottomTop: qsTr("Super+Ctrl+Shift+Down"),
        arrangeLeftQuarters: qsTr("Super+Ctrl+Alt+Shift+Left"),
        arrangeRightQuarters: qsTr("Super+Ctrl+Alt+Shift+Right"),
        arrangeTopQuarters: qsTr("Super+Ctrl+Alt+Shift+Up"),
        arrangeBottomQuarters: qsTr("Super+Ctrl+Alt+Shift+Down")
    })

    // ---- Window tiling rows (docs/specs/tiling.md TL23, TL25): glyphs from the tiling.* tokens ----

    // The zones of a layout of the catalogue (the tiling.layout* tokens: [x, y, w, h] in twelfths).
    readonly property var layoutZones: ({
            "left-right": Tokens.tilingLayoutLeftRight,
            "right-left": Tokens.tilingLayoutRightLeft,
            "top-bottom": Tokens.tilingLayoutTopBottom,
            "bottom-top": Tokens.tilingLayoutBottomTop,
            "quarters": Tokens.tilingLayoutQuarters,
            "left-quarters": Tokens.tilingLayoutLeftQuarters,
            "right-quarters": Tokens.tilingLayoutRightQuarters,
            "top-quarters": Tokens.tilingLayoutTopQuarters,
            "bottom-quarters": Tokens.tilingLayoutBottomQuarters,
            "wide-left": Tokens.tilingLayoutWideLeft,
            "thirds": Tokens.tilingLayoutThirds,
            "wide-center": Tokens.tilingLayoutWideCenter,
            "four-columns": Tokens.tilingLayoutFourColumns,
            "stacked-thirds": Tokens.tilingLayoutStackedThirds
        })

    // The Layouts section of an output class (owner decision T1f, the tiling.class* tokens; WindowTiling.outputClass).
    readonly property var classLayouts: ({
            "small": Tokens.tilingClassSmall,
            "large": Tokens.tilingClassLarge,
            "ultrawide": Tokens.tilingClassUltraWide,
            "portrait": Tokens.tilingClassPortrait
        })

    // A place's glyph: its zone alone (the halves and quarters are zones of the catalogue; Fill the whole screen).
    function placeGlyph(place: string): var {
        const quarters = Tokens.tilingLayoutQuarters;
        const zone = {
            "left": Tokens.tilingLayoutLeftRight[0],
            "right": Tokens.tilingLayoutLeftRight[1],
            "top": Tokens.tilingLayoutTopBottom[0],
            "bottom": Tokens.tilingLayoutTopBottom[1],
            "top-left": quarters[0],
            "top-right": quarters[1],
            "bottom-left": quarters[2],
            "bottom-right": quarters[3],
            "fill": [0, 0, 12, 12],
            "center": Tokens.tilingGlyphCenter[0]
        }[place];
        return zone ? {zones: [zone], own: 0} : null;
    }

    // An arrangement's glyph: the window's own zone (the first) in full, the others light; Quarters, four equal windows, in full
    // (as macOS draws it).
    function layoutGlyph(layout: string): var {
        const zones = root.layoutZones[layout];
        return zones ? {zones: zones, own: layout === "quarters" ? -1 : 0} : null;
    }

    readonly property var placeNames: ({
            "left": qsTr("Left"),
            "right": qsTr("Right"),
            "top": qsTr("Top"),
            "bottom": qsTr("Bottom"),
            "top-left": qsTr("Top Left"),
            "top-right": qsTr("Top Right"),
            "bottom-left": qsTr("Bottom Left"),
            "bottom-right": qsTr("Bottom Right"),
            "fill": qsTr("Fill"),
            "center": qsTr("Center"),
            "previous": qsTr("Return to Previous Size")
        })

    readonly property var layoutNames: ({
            "left-right": qsTr("Left & Right"),
            "right-left": qsTr("Right & Left"),
            "top-bottom": qsTr("Top & Bottom"),
            "bottom-top": qsTr("Bottom & Top"),
            "quarters": qsTr("Quarters"),
            "left-quarters": qsTr("Left & Quarters"),
            "right-quarters": qsTr("Right & Quarters"),
            "top-quarters": qsTr("Top & Quarters"),
            "bottom-quarters": qsTr("Bottom & Quarters"),
            "wide-left": qsTr("Two Thirds & One Third"),
            "thirds": qsTr("Thirds"),
            "wide-center": qsTr("Quarter, Half & Quarter"),
            "four-columns": qsTr("Four Columns"),
            "stacked-thirds": qsTr("Stacked Thirds")
        })

    readonly property var placeShortcuts: ({
            "left": root.shortcuts.tileLeft,
            "right": root.shortcuts.tileRight,
            "top": root.shortcuts.tileTop,
            "bottom": root.shortcuts.tileBottom,
            "top-left": root.shortcuts.tileTopLeft,
            "top-right": root.shortcuts.tileTopRight,
            "bottom-left": root.shortcuts.tileBottomLeft,
            "bottom-right": root.shortcuts.tileBottomRight,
            "fill": root.shortcuts.tileFill,
            "center": root.shortcuts.tileCenter,
            "previous": root.shortcuts.tilePrevious
        })

    readonly property var layoutShortcuts: ({
            "left-right": root.shortcuts.arrangeLeftRight,
            "right-left": root.shortcuts.arrangeRightLeft,
            "top-bottom": root.shortcuts.arrangeTopBottom,
            "bottom-top": root.shortcuts.arrangeBottomTop,
            "left-quarters": root.shortcuts.arrangeLeftQuarters,
            "right-quarters": root.shortcuts.arrangeRightQuarters,
            "top-quarters": root.shortcuts.arrangeTopQuarters,
            "bottom-quarters": root.shortcuts.arrangeBottomQuarters
        })

    function tileItem(place: string, enabled: bool): var {
        const glyph = root.placeGlyph(place);
        const item = {id: "tile", place: place, text: root.placeNames[place], shortcut: root.placeShortcuts[place] || "", enabled: enabled};
        if (glyph)
            item.glyph = glyph;
        return item;
    }

    function arrangeItem(layout: string, enabled: bool): var {
        return {id: "arrange", layout: layout, text: root.layoutNames[layout], shortcut: root.layoutShortcuts[layout] || "", glyph: root.layoutGlyph(layout), enabled: enabled};
    }

    // An output as Settings > Displays names it (M23): the built-in panel, else its model, else its connector.
    function outputLabel(output: var): string {
        if (output.builtIn)
            return qsTr("Built-in Display");
        return output.model !== "" ? output.model : output.name;
    }

    function moveToOutputItems(outputs: var, enabled: bool): var {
        return (outputs || []).map(o => ({id: "moveToOutput", output: o.name, text: qsTr("Move to %1").arg(root.outputLabel(o)), iconName: "display", enabled: enabled}));
    }

    // The Layouts section (TL27, owner decisions T1a, T1f): the layouts of an output class, each a miniature screen whose zones
    // the window can take; greyed when it cannot be tiled now. [{id, text, zones, enabled}]; [] for an unknown class.
    function layoutsSection(outputClass: string, enabled: bool): var {
        const ids = root.classLayouts[outputClass] || [];
        return ids.filter(id => root.layoutZones[id] !== undefined).map(id => ({id: id, text: root.layoutNames[id], zones: root.layoutZones[id], enabled: enabled}));
    }

    // The tiling popover of the zoom light (TL23): ctx {alt, tileable, canArrange, canLayouts, canSplit, splitBlocked, splittable,
    // outputClass, fullscreen, inSplit, outputs} (`splittable` false: the window does not fit half of its output, TL8).
    // {sections: [{title, items}], layouts, rows}: the glyph sections Move & Resize and Fill & Arrange (with
    // Alt: the quarters, Center, Right & Left and Right & Quarters), the Layouts section of the window's output class (with the
    // plugin's tiling-layouts, layoutsSection), then Full Screen (fullScreenRow) and one Move to <display> row per other output;
    // in full screen or on a Split View Desktop only Exit Full Screen. The glyphs of a window that cannot be tiled now are greyed.
    function tilingPopover(ctx: var): var {
        if (ctx.fullscreen || ctx.inSplit)
            return {sections: [], layouts: [], rows: [{id: ctx.inSplit ? "exitSplit" : "fullscreen", text: qsTr("Exit Full Screen"), glyph: {zones: [], own: -1}, enabled: true}]};
        const can = ctx.tileable === true;
        const arrange = can && ctx.canArrange === true;
        const places = ctx.alt ? ["top-left", "top-right", "bottom-left", "bottom-right"] : ["left", "right", "top", "bottom"];
        return {
            sections: [
                {title: qsTr("Move & Resize"), items: places.map(p => root.tileItem(p, can))},
                {title: qsTr("Fill & Arrange"), items: [
                        root.tileItem(ctx.alt ? "center" : "fill", can),
                        root.arrangeItem(ctx.alt ? "right-left" : "left-right", arrange),
                        root.arrangeItem(ctx.alt ? "right-quarters" : "left-quarters", arrange),
                        root.arrangeItem("quarters", arrange)
                    ]}
            ],
            layouts: ctx.canLayouts === true ? root.layoutsSection(ctx.outputClass, can) : [],
            rows: [root.fullScreenRow(ctx.canSplit === true, can && ctx.splitBlocked !== true && ctx.splittable !== false)].concat(root.moveToOutputItems(ctx.outputs, can))
        };
    }

    // Left or Right of Screen (docs/specs/tiling.md TL33): the window's own half in full, the other light.
    function splitItem(side: string, enabled: bool): var {
        return {id: "split", side: side, text: side === "left" ? qsTr("Left of Screen") : qsTr("Right of Screen"), glyph: {zones: Tokens.tilingLayoutLeftRight, own: side === "left" ? 0 : 1}, enabled: enabled};
    }

    // The popover's Full Screen row: with the plugin's tiling-split the submenu Full Screen › Entire Screen, Left of Screen,
    // Right of Screen (TL33, the step ADR-0036 D17 waited for; the halves greyed for a window that cannot be tiled now and
    // while Stages shows its strip, D47), else the row that enters full screen.
    function fullScreenRow(canSplit: bool, splittable: bool): var {
        const row = {id: "fullscreen", text: qsTr("Full Screen"), glyph: {zones: [], own: -1}, enabled: true};
        if (!canSplit)
            return row;
        return Object.assign(row, {id: "fullScreenMenu", submenu: [
                    {id: "fullscreen", text: qsTr("Entire Screen"), glyph: root.placeGlyph("fill"), enabled: true},
                    root.splitItem("left", splittable),
                    root.splitItem("right", splittable)
                ]});
    }

    // Longest window title shown in the Window menu.
    readonly property int titleMax: 40

    function elide(title: string, max: int): string {
        const t = String(title).replace(/\s+/g, " ").trim();
        return t.length > max ? t.slice(0, max - 1) + "…" : t;
    }

    function appMenu(ctx: var): var {
        const has = ctx.hasApp;
        const n = ctx.appName;
        return [
            {id: "about", text: has ? qsTr("About %1").arg(n) : qsTr("About Desktop"), enabled: has},
            {separator: true},
            {id: "hide", text: has ? qsTr("Hide %1").arg(n) : qsTr("Hide"), shortcut: root.shortcuts.hide, enabled: has},
            {id: "hideOthers", text: qsTr("Hide Others"), enabled: has && ctx.othersCount > 0},
            {id: "showAll", text: qsTr("Show All"), enabled: ctx.hiddenCount > 0},
            {separator: true},
            {id: "quit", text: has ? qsTr("Quit %1").arg(n) : qsTr("Quit"), enabled: has && ctx.windows.length > 0}
        ];
    }

    // Real items only: [] when the app offers nothing (the File menu is then not shown).
    function fileMenu(ctx: var): var {
        const entry = ctx.entry;
        if (!ctx.hasApp || !entry)
            return [];
        const actions = entry.actions ? entry.actions : [];
        const items = [];
        // New Window only when the entry declares a `new-window` action (R11). Launching the entry
        // again is not known to open a window (SingleMainWindow=true, single-instance apps), so
        // without that action the item is not shown.
        if (actions.some(a => a.id === "new-window"))
            items.push({id: "newWindow", text: qsTr("New Window")});
        const others = [];
        for (let i = 0; i < actions.length; i++) {
            if (actions[i].id !== "new-window")
                others.push({id: "entryAction", index: i, text: actions[i].name});
        }
        if (others.length > 0 && items.length > 0)
            items.push({separator: true});
        return items.concat(others);
    }

    function hasFileMenu(ctx: var): bool {
        return fileMenu(ctx).length > 0;
    }

    function windowMenu(ctx: var): var {
        const fw = ctx.focusedWindow;
        const focusedMinimized = fw ? ctx.windows.some(w => w.ref === fw && w.minimized) : false;
        // displayOnly: the app is named from the Stages event while no window is key (macOS greys window commands then).
        const canAct = fw !== null && fw !== undefined && !focusedMinimized && ctx.displayOnly !== true;
        // Desktops are numbered by position, as in Overview (macOS), never by the compositor's workspace id.
        const spaces = ctx.spaces.map((s, i) => ({
            id: "moveTo",
            space: s.id,
            text: qsTr("Desktop %1").arg(i + 1),
            checked: s.id === ctx.windowSpaceId,
            enabled: s.id !== ctx.windowSpaceId
        }));
        spaces.push({separator: true});
        spaces.push({id: "moveToNew", space: ctx.newSpaceId, text: qsTr("New Desktop")});

        // Window tiling (macOS 15+, TL25): Fill, Center, Move & Resize and Move to <display>, placed by the compositor plugin
        // (window-tiling). The plugin places floating windows only: not in full screen, not zoomed (unzoom first, as macOS greys
        // them for a zoomed window). Move & Resize has the headed sections Halves, Quarters and Arrange (with Alt the "&
        // Quarters" alternates in place, M28; with the plugin's tiling-arrange only), then Return to Previous Size. A window of a
        // Split View Desktop (TL33) is placed by its Desktop: no tiling command, no Zoom.
        // A window of fixed size (ADR-0040 step 1b): its zoom light is disabled, and so are Zoom, Enter Full Screen and the
        // tiling items (macOS greys them for a window that cannot be resized); Unzoom and Exit Full Screen still bring it back.
        const fixed = ctx.fixedSize === true;
        const canTile = canAct && ctx.canTile === true && !ctx.fullscreen && !ctx.maximized && ctx.inSplit !== true && !fixed;
        const arrange = (layout, quarters) => Object.assign(root.arrangeItem(layout, canTile), {alternate: root.arrangeItem(quarters, canTile)});
        const arrangeRows = ctx.canArrange === true ? [
            {separator: true},
            {header: true, text: qsTr("Arrange")},
            arrange("left-right", "left-quarters"),
            arrange("right-left", "right-quarters"),
            arrange("top-bottom", "top-quarters"),
            arrange("bottom-top", "bottom-quarters"),
            root.arrangeItem("quarters", canTile)
        ] : [];
        const tiling = ctx.canTile === true ? [
            root.tileItem("fill", canTile),
            root.tileItem("center", canTile),
            {separator: true},
            {id: "moveResize", text: qsTr("Move & Resize"), enabled: canTile, submenu: [
                    {header: true, text: qsTr("Halves")},
                    root.tileItem("left", canTile),
                    root.tileItem("right", canTile),
                    root.tileItem("top", canTile),
                    root.tileItem("bottom", canTile),
                    {separator: true},
                    {header: true, text: qsTr("Quarters")},
                    root.tileItem("top-left", canTile),
                    root.tileItem("top-right", canTile),
                    root.tileItem("bottom-left", canTile),
                    root.tileItem("bottom-right", canTile)
                ].concat(arrangeRows, [
                    {separator: true},
                    root.tileItem("previous", canTile)
                ])}
        ].concat(root.moveToOutputItems(ctx.outputs, canTile), [{separator: true}]) : [];

        // Full Screen (TL33): on a Split View Desktop Exit Full Screen sends the window back (Compositor.unsplit); else Enter or Exit
        // Full Screen, then with the plugin's tiling-split Full Screen Tile › Left of Screen, Right of Screen (M29), greyed with
        // the tiling items, while Stages shows its strip (D47) and for a window that does not fit half of its output (`splittable`
        // false, D57).
        const canSplit = canTile && ctx.splitBlocked !== true && ctx.splittable !== false;
        const fullScreen = ctx.inSplit === true ? [{id: "exitSplit", text: qsTr("Exit Full Screen"), enabled: canAct}] : [
            {id: "fullscreen", text: ctx.fullscreen ? qsTr("Exit Full Screen") : qsTr("Enter Full Screen"), shortcut: root.shortcuts.fullscreen, enabled: canAct && (ctx.fullscreen || !fixed)}
        ].concat(ctx.canSplit === true ? [{id: "fullScreenTile", text: qsTr("Full Screen Tile"), enabled: canSplit, submenu: [root.splitItem("left", canSplit), root.splitItem("right", canSplit)]}] : []);

        const items = [
            // A window in full screen or on a Split View Desktop is not minimized (macOS; D56, D61).
            {id: "minimize", text: qsTr("Minimize"), shortcut: root.shortcuts.minimize, enabled: canAct && ctx.inSplit !== true && ctx.fullscreen !== true},
            {id: "zoom", text: ctx.maximized ? qsTr("Unzoom") : qsTr("Zoom"), shortcut: root.shortcuts.zoom, enabled: canAct && ctx.inSplit !== true && (ctx.maximized || !fixed)}
        ].concat(tiling, fullScreen, [
            {separator: true},
            {id: "moveMenu", text: qsTr("Move to Desktop"), enabled: canAct, submenu: spaces},
            {separator: true},
            {id: "bringAll", text: qsTr("Bring All to Front"), enabled: ctx.windows.length > 0}
        ]);
        if (ctx.windows.length > 0) {
            items.push({separator: true});
            for (let i = 0; i < ctx.windows.length; i++) {
                const w = ctx.windows[i];
                const title = elide(w.title !== "" ? w.title : ctx.appName, root.titleMax);
                items.push({id: "window", ref: w.ref, text: w.minimized ? qsTr("%1 (minimized)").arg(title) : title, checked: w.focused});
            }
        }
        return items;
    }
}
