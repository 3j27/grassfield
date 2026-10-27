import QtQuick
import QtTest
import "../../shell/services/ClipboardLogic.js" as Logic

// The clipboard history on the shell side (ADR-0034): when a copy may be recorded, which display the helper is given, the
// helper's lines and items, when the paste may be sent and the Lua function sent for it. Pure logic of
// shell/services/ClipboardLogic.js; the helper itself is tests/unit/clipboard-helper and tests/shell/clipboard_helper.sh.
TestCase {
    name: "Clipboard"

    readonly property string us: "\x1f"

    function readRepo(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        return xhr.responseText;
    }

    function open(over) {
        const s = {
            enabled: true,
            locked: false,
            helperLocked: false,
            authorizing: false,
            authorizingGrace: false,
            activeClass: "org.gnome.TextEditor"
        };
        for (const k in over)
            s[k] = over[k];
        return s;
    }

    function test_recordOnlyWhenEverythingAllows() {
        verify(Logic.mayRecord(open({})));
        verify(!Logic.mayRecord(open({enabled: false})), "the history off");
        verify(!Logic.mayRecord(open({locked: true})), "the shell's lock (or its locking phase)");
        verify(!Logic.mayRecord(open({helperLocked: true})), "a lock by another program (the compositor's notifier)");
        verify(!Logic.mayRecord(open({authorizing: true})), "an authorization request open");
        verify(!Logic.mayRecord(open({authorizingGrace: true})), "an authorization request ended less than 2 s ago");
        compare(Logic.AUTH_GRACE_MS, 2000);
        verify(!Logic.mayRecord(open({activeClass: "1Password"})), "a protected password manager in front");
        verify(!Logic.mayRecord(open({activeClass: "Bitwarden"})));
        verify(!Logic.mayRecord(open({activeClass: "chrome-nngceckbapebfimnlniiiahkandclblb-Default"})));
        verify(Logic.mayRecord(open({activeClass: ""})), "no window in front");
        // Anything that is not exactly the open value is a refusal (fail closed).
        verify(!Logic.mayRecord(open({locked: undefined})));
        verify(!Logic.mayRecord(open({authorizingGrace: undefined})));
        verify(!Logic.mayRecord(open({enabled: "true"})));
        verify(!Logic.mayRecord(null));
    }

    function test_protectedClassesAreThoseOfPrivacyLua() {
        const lua = readRepo("config/hypr/grassfield/privacy.lua");
        const block = lua.slice(lua.indexOf("local BUILTIN = {"), lua.indexOf("}\n", lua.indexOf("local BUILTIN = {")) + 1);
        const found = [];
        const re = /class = "([^"]+)"/g;
        let m;
        while ((m = re.exec(block)) !== null)
            found.push(m[1]);
        compare(found.join(" "), Logic.PROTECTED_CLASSES.join(" "));
    }

    function test_terminalTestIsForwardingLuas() {
        const lua = readRepo("config/hypr/grassfield/forwarding.lua");
        const line = lua.split("\n").find(l => l.startsWith("local TERMINAL_CLASSES = {"));
        const classes = [];
        const re = /"([^"]+)"/g;
        let m;
        while ((m = re.exec(line)) !== null)
            classes.push(m[1]);
        compare(classes.join(" "), Logic.TERMINAL_CLASSES.join(" "));
        verify(lua.indexOf("class:find(\"^org%.omarchy%.\")") >= 0 && lua.indexOf("class:find(\"^tui%.\")") >= 0, "the prefixes are forwarding.lua's");
        compare(Logic.TERMINAL_PREFIXES.join(" "), "org.omarchy. tui.");
        verify(Logic.isTerminalClass("Alacritty"));
        verify(Logic.isTerminalClass("org.omarchy.terminal"));
        verify(Logic.isTerminalClass("TUI.float"));
        verify(!Logic.isTerminalClass("org.gnome.TextEditor"));
        verify(!Logic.isTerminalClass("kittyish"));
    }

    function test_displayIsOnlyTheOneGiven() {
        // A dev session: only GRASSFIELD_CLIPBOARD_DISPLAY, absolute; never the session's WAYLAND_DISPLAY.
        compare(Logic.displayPath(true, "", "/run/user/1000", "wayland-1"), "");
        compare(Logic.displayPath(true, "wayland-2", "/run/user/1000", "wayland-1"), "");
        compare(Logic.displayPath(true, "/run/user/1000/wayland-2", "/run/user/1000", "wayland-1"), "/run/user/1000/wayland-2");
        // A real session: the session's socket.
        compare(Logic.displayPath(false, "/tmp/x", "/run/user/1000", "wayland-1"), "/run/user/1000/wayland-1");
        compare(Logic.displayPath(false, "", "/run/user/1000/", "/abs/wayland-9"), "/abs/wayland-9");
        compare(Logic.displayPath(false, "", "", "wayland-1"), "");
        compare(Logic.displayPath(false, "", "relative", "wayland-1"), "");
        compare(Logic.displayPath(false, "", "/run/user/1000", "../wayland-1"), "");
        compare(Logic.runtimeDir("/run/user/1000", "/run/user/1000/wayland-1"), "/run/user/1000/grassfield/clipboard-wayland-1");
        compare(Logic.runtimeDir("/run/user/1000", "/tmp/a b"), "/run/user/1000/grassfield/clipboard-a_b");
        compare(Logic.runtimeDir("", "/run/user/1000/wayland-1"), "");
    }

    function test_retention() {
        compare(Logic.retentionMs("30m"), 1800000);
        compare(Logic.retentionMs("8h"), 28800000);
        compare(Logic.retentionMs("7d"), 604800000);
        compare(Logic.retentionMs("forever"), 28800000);
        const schema = JSON.parse(readRepo("config/schema/grassfield.schema.json"));
        const r = schema.properties.search.properties.clipboard.properties.retention;
        compare(r.enum.join(","), "30m,8h,7d");
        compare(r["default"], "8h");
    }

    function test_linesAndItems() {
        const raw = "a\\b\nc\rd" + us + "e";
        compare(Logic.unescapeField(Logic.escapeField(raw)), raw);
        verify(Logic.line(["Q", "1", raw]).split(us).length === 3);
        const f = Logic.parseLine(["I", "00000000000000a1", "text", "text/plain,text/html", "23", "100", "0", "1", "0",
            Logic.escapeField("Hello\nworld"), "Hello", "", "org.example.App"].join(us));
        const item = Logic.parseItem(f);
        compare(item.id, "00000000000000a1");
        compare(item.title, "Hello\nworld");
        compare(item.mimes.length, 2);
        verify(item.formatted);
        verify(!item.pinned);
        compare(Logic.parseItem(["I", "../../etc", "text"]), null);
        let items = [];
        items = Logic.upsert(items, {id: "a", pinned: false, pinnedAt: 0, copiedAt: 1});
        items = Logic.upsert(items, {id: "b", pinned: false, pinnedAt: 0, copiedAt: 3});
        items = Logic.upsert(items, {id: "c", pinned: true, pinnedAt: 5, copiedAt: 0});
        items = Logic.upsert(items, {id: "a", pinned: false, pinnedAt: 0, copiedAt: 9});
        compare(items.map(i => i.id).join(""), "cab", "pins first, then newest copy first; an update moves the item");
        compare(Logic.removeId(items, "a").map(i => i.id).join(""), "cb");
    }

    function test_pasteOnlyIntoTheRememberedWindow() {
        const ok = {
            locked: false,
            helperLocked: false,
            rememberedAddress: "0x55d0c0ffee",
            activeAddress: "0x55d0c0ffee",
            closedSinceOpen: false,
            otherSurfaceOpen: false,
            elapsedMs: 200
        };
        verify(Logic.mayPaste(ok));
        const refuse = {
            locked: true,
            helperLocked: true,
            activeAddress: "0x1",
            closedSinceOpen: true,
            otherSurfaceOpen: true,
            elapsedMs: 1001
        };
        for (const k in refuse) {
            const s = Object.assign({}, ok);
            s[k] = refuse[k];
            verify(!Logic.mayPaste(s), k);
        }
        verify(!Logic.mayPaste(Object.assign({}, ok, {rememberedAddress: "", activeAddress: ""})), "no window was active at open");
    }

    function test_pasteRequest() {
        compare(Logic.pasteRequest("0x1; os.exit()"), "");
        compare(Logic.pasteRequest(""), "");
        const r = Logic.pasteRequest("0x55d0c0ffee");
        verify(r.startsWith("function() local w = hl.get_active_window(); if not w or w.address ~= \"0x55d0c0ffee\" then return end;"),
            "the window is checked first, in the same call");
        // The key down and the key up both go to the address; the up's timer is armed first, in the same function, and checks
        // nothing.
        const check = r.indexOf("get_active_window");
        const timer = r.indexOf("hl.timer(function()");
        const up = r.indexOf("state = \"up\", window = \"address:0x55d0c0ffee\"");
        const down = r.indexOf("state = \"down\", window = \"address:0x55d0c0ffee\"");
        verify(check > 0 && timer > check && up > timer && down > up, "check, then the key up's timer, then the key down");
        compare(r.slice(timer).indexOf("get_active_window"), -1, "the key up never checks the active window again");
        verify(r.indexOf("mods = terminal and \"CTRL SHIFT\" or \"CTRL\"") > 0);
        verify(r.indexOf("\"org%.omarchy%.\"") > 0, "the Lua pattern escapes the prefixes' dots");
    }
}
