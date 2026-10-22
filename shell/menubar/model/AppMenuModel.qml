import QtQml

// Application menu models (T0, docs/specs/menubar.md). Pure: builds menu item arrays from a
// plain context object, so it is unit-tested without a compositor (tests/unit/tst_appmenumodel.qml).
//
// ctx: {displayOnly?: bool (app named from the Stages event, no key window: window commands disabled), hasApp, appName, entry: {id, actions: [{id, name}]} | null, singleMain: bool,
//       windows: [{ref, title, focused, minimized}], focusedWindow: ref | null,
//       fullscreen: bool, maximized: bool, windowSpaceId: int,
//       othersCount: int, hiddenCount: int, spaces: [{id}], newSpaceId: int, canTile?: bool (plugin "window-tiling")}
// Items: {id, text, shortcut?, enabled?, checked?, separator?, submenu?, ...payload}; AppMenus.run()
// performs them.
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
        tilePrevious: qsTr("Super+Ctrl+R")
    })

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
        const spaces = ctx.spaces.map(s => ({
            id: "moveTo",
            space: s.id,
            text: qsTr("Desktop %1").arg(s.id),
            checked: s.id === ctx.windowSpaceId,
            enabled: s.id !== ctx.windowSpaceId
        }));
        spaces.push({separator: true});
        spaces.push({id: "moveToNew", space: ctx.newSpaceId, text: qsTr("New Desktop")});

        // Window tiling (macOS 15+): Fill, Center and Move & Resize, placed by the compositor plugin (window-tiling). The plugin
        // places floating windows only: not in full screen, not zoomed (unzoom first, as macOS greys them for a zoomed window).
        const canTile = canAct && ctx.canTile === true && !ctx.fullscreen && !ctx.maximized;
        const tile = (place, text, shortcut) => ({id: "tile", place: place, text: text, shortcut: shortcut, enabled: canTile});
        const tiling = ctx.canTile === true ? [
            tile("fill", qsTr("Fill"), ""),
            tile("center", qsTr("Center"), ""),
            {id: "moveResize", text: qsTr("Move & Resize"), enabled: canTile, submenu: [
                    tile("left", qsTr("Left"), root.shortcuts.tileLeft),
                    tile("right", qsTr("Right"), root.shortcuts.tileRight),
                    tile("top", qsTr("Top"), root.shortcuts.tileTop),
                    tile("bottom", qsTr("Bottom"), root.shortcuts.tileBottom),
                    {separator: true},
                    tile("top-left", qsTr("Top Left"), ""),
                    tile("top-right", qsTr("Top Right"), ""),
                    tile("bottom-left", qsTr("Bottom Left"), ""),
                    tile("bottom-right", qsTr("Bottom Right"), ""),
                    {separator: true},
                    tile("previous", qsTr("Return to Previous Size"), root.shortcuts.tilePrevious)
                ]},
            {separator: true}
        ] : [];

        const items = [
            {id: "minimize", text: qsTr("Minimize"), shortcut: root.shortcuts.minimize, enabled: canAct},
            {id: "zoom", text: ctx.maximized ? qsTr("Unzoom") : qsTr("Zoom"), shortcut: root.shortcuts.zoom, enabled: canAct}
        ].concat(tiling.length > 0 ? [{separator: true}].concat(tiling) : [], [
            {id: "fullscreen", text: ctx.fullscreen ? qsTr("Exit Full Screen") : qsTr("Enter Full Screen"), shortcut: root.shortcuts.fullscreen, enabled: canAct},
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
