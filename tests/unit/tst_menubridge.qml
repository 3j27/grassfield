import QtQuick
import QtTest
import "../../shell/platform/MenuBridge.js" as Bridge
import "../../shell/platform/Minimized.js" as Minimized

// Shell side of the global menus (shell/platform/MenuBridge.js): gfc/1 appmenu events, menu/1 lines to and from
// grassfield-menu-bridge (validation of untrusted data), menu bar models.
TestCase {
    name: "MenuBridge"

    function event(fields) {
        return JSON.stringify(Object.assign({v: "gfc/1", type: "appmenu"}, fields));
    }

    function test_appmenuEvents() {
        compare(Bridge.parseAppmenuEvent(event({address: "55D3C2A0B1F0", service: ":1.42", path: "/MenuBar/1", pid: 4242})),
                {address: "55d3c2a0b1f0", service: ":1.42", path: "/MenuBar/1", pid: 4242});
        // A clear: no menu for the window.
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: "", path: "", pid: 0})), {address: "1a", service: "", path: "", pid: 0});
        // A plugin without the pid field: accepted, pid 0 (the bridge is then never asked to open it).
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: "org.kde.Foo", path: "/a"})).pid, 0);
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: ":1.2", path: "/a", pid: -3})).pid, 0);
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: ":1.2", path: "/a", pid: 1.5})).pid, 0);
        // Rejected.
        compare(Bridge.parseAppmenuEvent("not json"), null);
        compare(Bridge.parseAppmenuEvent(JSON.stringify({v: "gfc/2", type: "appmenu", address: "1a", service: "", path: ""})), null);
        compare(Bridge.parseAppmenuEvent(event({type: "minimized", address: "1a"})), null);
        compare(Bridge.parseAppmenuEvent(event({address: "zz", service: ":1.2", path: "/a"})), null);
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: "org foo", path: "/a"})), null);
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: ":1.2", path: "relative"})), null);
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: ":1.2", path: "/a/"})), null);
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: ":1.2"})), null);
        compare(Bridge.parseAppmenuEvent(event({address: "1a", service: "", path: "/a"})), null);
    }

    function test_linesToTheBridge() {
        compare(Bridge.helloLine(true), "{\"type\":\"hello\",\"v\":\"menu/1\",\"appmenu\":true}\n");
        compare(Bridge.helloLine("yes"), "{\"type\":\"hello\",\"v\":\"menu/1\",\"appmenu\":false}\n");
        compare(Bridge.openLine("0x1A", {service: ":1.42", path: "/MenuBar/1", pid: 7}),
                "{\"type\":\"open\",\"window\":\"1a\",\"service\":\":1.42\",\"path\":\"/MenuBar/1\",\"pid\":7}\n");
        // Never sent without a pid, with an invalid name or path, or for an invalid window.
        compare(Bridge.openLine("1a", {service: ":1.42", path: "/MenuBar/1", pid: 0}), "");
        compare(Bridge.openLine("1a", {service: "x", path: "/MenuBar/1", pid: 7}), "");
        compare(Bridge.openLine("1a", {service: ":1.42", path: "MenuBar", pid: 7}), "");
        compare(Bridge.openLine("no", {service: ":1.42", path: "/MenuBar/1", pid: 7}), "");
        compare(Bridge.openLine("1a", null), "");
        compare(Bridge.itemLine("activate", "1a", 12), "{\"type\":\"activate\",\"window\":\"1a\",\"id\":12}\n");
        compare(Bridge.itemLine("about-to-show", "1a", 0), "{\"type\":\"about-to-show\",\"window\":\"1a\",\"id\":0}\n");
        compare(Bridge.itemLine("activate", "1a", -1), "");
        compare(Bridge.itemLine("activate", "1a", 1.5), "");
        compare(Bridge.itemLine("activate", "1a", "3"), "");
        compare(Bridge.itemLine("run", "1a", 3), "");
        compare(Bridge.closeLine("1A"), "{\"type\":\"close\",\"window\":\"1a\"}\n");
        compare(Bridge.closeLine(""), "");
    }

    function test_appmenuRequery() {
        compare(Minimized.appmenuCall("0x55AB"),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.appmenu then p.appmenu(\"0x55ab\") end end");
        compare(Minimized.appmenuCall("55ab\"); os.exit() --"), "");
        compare(Minimized.appmenuCall(""), "");
    }

    readonly property var sampleItems: [
        {id: 1, type: "standard", label: "File", enabled: true, visible: true, "toggle-type": "", "toggle-state": -1, shortcut: [], submenu: true, children: [
                {id: 2, type: "standard", label: "New", enabled: true, visible: true, "toggle-type": "", "toggle-state": -1, shortcut: [["Control", "N"]], submenu: false, children: []},
                {id: 3, type: "separator", label: "", enabled: true, visible: true, submenu: false, children: []},
                {id: 4, type: "separator", label: "", enabled: true, visible: true, submenu: false, children: []},
                {id: 5, type: "standard", label: "Redo", enabled: false, visible: true, shortcut: [["Control", "Shift", "z"]], submenu: false, children: []},
                {id: 6, type: "standard", label: "Secret", enabled: true, visible: false, submenu: false, children: []},
                {id: 7, type: "standard", label: "Word Wrap", enabled: true, visible: true, "toggle-type": "checkmark", "toggle-state": 1, submenu: false, children: []},
                {id: 8, type: "standard", label: "Theme", enabled: true, visible: true, submenu: true, children: [
                        {id: 9, type: "standard", label: "Dark", enabled: true, visible: true, "toggle-type": "radio", "toggle-state": 0, submenu: false, children: []}
                    ]},
                {id: 10, type: "standard", label: "Bookmarks", enabled: true, visible: true, submenu: true, children: []},
                {id: 11, type: "separator", label: "", enabled: true, visible: true, submenu: false, children: []}
            ]},
        {id: 12, type: "standard", label: "Edit", enabled: true, visible: true, submenu: true, children: []},
        {id: 13, type: "standard", label: "Hidden", enabled: true, visible: false, submenu: true, children: []},
        {id: 14, type: "separator", label: "", enabled: true, visible: true, submenu: false, children: []}
    ]

    function menuLine(items) {
        return JSON.stringify({type: "menu", window: "1a", revision: 3, items: items});
    }

    function test_menuLostCodes() {
        // A refusal on a re-read ("oversized", "backoff") must clear the menu that was on screen, like the older codes.
        for (const code of ["pid-mismatch", "no-owner", "gone", "layout-failed", "oversized", "backoff"])
            verify(Bridge.menuLost(code), code);
        for (const code of ["bad-request", "busy", "registrar-busy", "unknown-item", "unknown", ""])
            verify(!Bridge.menuLost(code), code);
    }

    function test_bridgeLines() {
        compare(Bridge.parseBridgeLine("{\"type\":\"status\",\"v\":\"menu/1\",\"state\":\"active\",\"registrar\":true}"), {type: "status", state: "active", registrar: true});
        compare(Bridge.parseBridgeLine("{\"type\":\"status\",\"v\":\"menu/9\",\"state\":\"active\",\"registrar\":true}"), null);
        compare(Bridge.parseBridgeLine("{\"type\":\"error\",\"window\":\"1A\",\"code\":\"pid-mismatch\",\"message\":\"no\\nway\"}"),
                {type: "error", window: "1a", code: "pid-mismatch", message: "no way"});
        compare(Bridge.parseBridgeLine("{\"type\":\"error\",\"code\":\"<b>x</b>\"}").code, "unknown");
        compare(Bridge.parseBridgeLine("garbage"), null);
        compare(Bridge.parseBridgeLine(""), null);
        compare(Bridge.parseBridgeLine("{\"type\":\"menu\",\"window\":\"xx\",\"revision\":1,\"items\":[]}"), null);
        compare(Bridge.parseBridgeLine("{\"type\":\"menu\",\"window\":\"1a\",\"revision\":-1,\"items\":[]}"), null);
        const msg = Bridge.parseBridgeLine(menuLine(sampleItems));
        compare(msg.type, "menu");
        compare(msg.window, "1a");
        compare(msg.revision, 3);
        compare(msg.items.length, 4);
        compare(msg.items[0].children[0].shortcut, [["Control", "N"]]);
        compare(msg.items[0].children[5].toggleType, "checkmark");
        compare(msg.items[0].children[5].toggleState, 1);
    }

    // ADR-0018: launcher lines (an application's own badge, progress and attention hint).
    function test_launcherLines() {
        compare(Bridge.parseBridgeLine("{\"type\":\"launcher\",\"app\":\"firefox\",\"count\":5,\"progress\":0.5,\"urgent\":true}"),
                {type: "launcher", app: "firefox", count: 5, progress: 0.5, urgent: true});
        compare(Bridge.parseBridgeLine("{\"type\":\"launcher\",\"app\":\"org.a-b_c.D\",\"count\":null,\"progress\":-1,\"urgent\":false}"),
                {type: "launcher", app: "org.a-b_c.D", count: null, progress: -1, urgent: false});
        // Missing keys read as null; all null is "forget this app".
        compare(Bridge.parseBridgeLine("{\"type\":\"launcher\",\"app\":\"x\"}"), {type: "launcher", app: "x", count: null, progress: null, urgent: null});
        compare(Bridge.parseBridgeLine("{\"type\":\"launcher\",\"app\":\"x\",\"count\":0}").count, 0);
        compare(Bridge.parseBridgeLine("{\"type\":\"launcher\",\"app\":\"x\",\"count\":99999}").count, 99999);
    }

    function test_launcherLinesAreValidated() {
        const bad = [
            "{\"type\":\"launcher\"}",
            "{\"type\":\"launcher\",\"app\":\"\"}",
            "{\"type\":\"launcher\",\"app\":5}",
            "{\"type\":\"launcher\",\"app\":\"a b\"}",
            "{\"type\":\"launcher\",\"app\":\"a/b\"}",
            "{\"type\":\"launcher\",\"app\":\"<b>\"}",
            "{\"type\":\"launcher\",\"app\":\"" + "a".repeat(256) + "\"}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"count\":-1}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"count\":100000}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"count\":1.5}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"count\":\"5\"}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"progress\":1.5}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"progress\":-2}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"progress\":\"0.5\"}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"urgent\":1}",
            "{\"type\":\"launcher\",\"app\":\"x\",\"urgent\":\"true\"}"
        ];
        for (const line of bad)
            compare(Bridge.parseBridgeLine(line), null, line);
        compare(Bridge.parseBridgeLine("{\"type\":\"launcher\",\"app\":\"" + "a".repeat(255) + "\"}").app.length, 255);
    }

    function test_untrustedItemsAreSanitized() {
        const items = Bridge.sanitizeItems([
            {id: -1, label: "negative"},
            {id: "2", label: "string id"},
            null,
            {id: 3, label: "a\u0007b\nc" + "x".repeat(400), shortcut: [["Control", "bad key"], ["Alt", "F4"]], "toggle-type": "switch", "toggle-state": 1, submenu: "yes"}
        ], 0, {items: 100});
        compare(items.length, 1);
        compare(items[0].label.length, 256);
        compare(items[0].label.indexOf("\u0007"), -1);
        compare(items[0].label.indexOf("\n"), -1);
        compare(items[0].shortcut, [["Alt", "F4"]]);
        compare(items[0].toggleType, "");
        compare(items[0].toggleState, -1);
        compare(items[0].submenu, false);
    }

    function test_depthAndCountCaps() {
        let deep = {id: 100, label: "leaf"};
        for (let i = 20; i >= 1; i--)
            deep = {id: i, label: "l" + i, submenu: true, children: [deep]};
        let level = Bridge.sanitizeItems([deep], 0, {items: 100});
        let depth = 0;
        while (level.length > 0) {
            depth++;
            level = level[0].children;
        }
        compare(depth, Bridge.limits.depth);
        const many = [];
        for (let i = 0; i < 3000; i++)
            many.push({id: i, label: "x"});
        compare(Bridge.sanitizeItems(many, 0, {items: Bridge.limits.items}).length, Bridge.limits.items);
    }

    function test_menuBarModels() {
        const items = Bridge.parseBridgeLine(menuLine(sampleItems)).items;
        compare(Bridge.topLevel(items), [{dbusId: 1, title: "File", enabled: true}, {dbusId: 12, title: "Edit", enabled: true}]);
        compare(Bridge.findItem(items, 9).label, "Dark");
        compare(Bridge.findItem(items, 999), null);
        const model = Bridge.popupModel(Bridge.findItem(items, 1).children);
        // New, one separator (doubles collapsed), Redo (disabled), Word Wrap (checked), Theme (submenu), Bookmarks
        // (empty submenu: shown, disabled); the hidden item and the trailing separator are left out.
        compare(model.map(m => m.separator ? "-" : m.text), ["New", "-", "Redo", "Word Wrap", "Theme", "Bookmarks"]);
        compare(model[0], {id: "bridge", dbusId: 2, text: "New", shortcut: "Ctrl+N", enabled: true, checked: false});
        compare(model[2].enabled, false);
        compare(model[2].shortcut, "Ctrl+Shift+Z");
        compare(model[3].checked, true);
        compare(model[4].submenu.length, 1);
        compare(model[4].submenu[0].checked, false);
        compare(model[5].enabled, false);
        compare(model[5].submenu, undefined);
    }

    function test_shortcutText() {
        compare(Bridge.shortcutText([["Control", "plus"]]), "Ctrl++");
        compare(Bridge.shortcutText([["Super", "Shift", "Delete"]]), "Super+Shift+Del");
        compare(Bridge.shortcutText([["F5"], ["Control", "r"]]), "F5");
        compare(Bridge.shortcutText([]), "");
    }
}
