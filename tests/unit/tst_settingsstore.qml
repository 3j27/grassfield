import QtQuick
import QtTest
import "../../apps/settings/qml/Store.js" as Store
import "../../apps/settings/qml/Bindings.js" as Bindings
import "../../apps/settings/qml/SysInfo.js" as SysInfo

// grassfield-settings logic: JSON merge/validation, ConfigStore refusal of malformed files, parsers.
TestCase {
    id: testCase
    name: "SettingsStore"

    Component {
        id: fakeBackend
        QtObject {
            property string configFile: "/fake/grassfield.json"
            property bool exists: true
            property string text: ""
            property int writes: 0
            signal fileChanged(string path)
            function readText(path: string): var {
                return {exists: exists, ok: exists, text: exists ? text : ""};
            }
            function writeText(path: string, t: string): string {
                text = t;
                exists = true;
                writes++;
                return "";
            }
            function watch(path: string): bool {
                return true;
            }
        }
    }

    function makeStore(initial, exists) {
        const backend = createTemporaryObject(fakeBackend, testCase, {text: initial, exists: exists !== false});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/ConfigStore.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const store = createTemporaryObject(comp, testCase, {backend: backend});
        verify(store);
        return {backend: backend, store: store};
    }

    function readSchema() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/schema/grassfield.schema.json"), false);
        xhr.send();
        return JSON.parse(xhr.responseText);
    }

    // Dotted paths of every scalar leaf in the schema (arrays such as dock.pinned are leaves).
    function schemaLeaves(node, prefix, out) {
        for (const key in node.properties) {
            const child = node.properties[key];
            const path = prefix === "" ? key : prefix + "." + key;
            if (child.type === "object")
                schemaLeaves(child, path, out);
            else
                out[path] = child;
        }
        return out;
    }

    function test_schemaParity() {
        const leaves = schemaLeaves(readSchema(), "", {});
        // Owned by other modules: version is fixed, dock.pinned belongs to the Dock.
        delete leaves["version"];
        delete leaves["dock.pinned"];
        compare(Object.keys(Store.RULES).sort(), Object.keys(leaves).sort());
        compare(Object.keys(Store.DEFAULTS).sort(), Object.keys(leaves).sort());
        for (const path in leaves) {
            const s = leaves[path];
            const r = Store.RULES[path];
            if (s.enum)
                compare(r.values, s.enum, path);
            if (s.minimum !== undefined)
                compare(r.min, s.minimum, path);
            if (s.maximum !== undefined)
                compare(r.max, s.maximum, path);
            compare(r.type === "integer" ? "integer" : r.type === "enum" ? "string" : r.type, s.type, path);
            // Defaults satisfy their own rule.
            compare(Store.validate(path, Store.DEFAULTS[path]), "", path);
        }
    }

    function test_defaultsMatchDefaultFile() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/defaults/grassfield.json"), false);
        xhr.send();
        const file = JSON.parse(xhr.responseText);
        for (const path in Store.DEFAULTS)
            compare(Store.read(file, path), Store.DEFAULTS[path], path);
    }

    function test_validate() {
        compare(Store.validate("material.transparency", 0.5), "");
        verify(Store.validate("material.transparency", 1.5) !== "");
        verify(Store.validate("material.transparency", "0.5") !== "");
        verify(Store.validate("material.transparency", NaN) !== "");
        verify(Store.validate("lock.idleMinutes", 2.5) !== "");
        verify(Store.validate("lock.idleMinutes", 241) !== "");
        compare(Store.validate("lock.idleMinutes", 0), "");
        verify(Store.validate("hotCorners.topLeft", "reboot") !== "");
        verify(Store.validate("dock.autohide", "yes") !== "");
        verify(Store.validate("dock.pinned", ["x"]) !== "", "keys outside RULES are refused");
        verify(Store.validate("bogus.key", 1) !== "");
    }

    function test_setValuePreservesOtherKeys() {
        const before = {version: 1, appearance: "dark", dock: {pinned: ["foot", "x"], magnification: 1.6}, extra: {a: [1, 2]}};
        const r = Store.setValue(JSON.stringify(before), "dock.autohide", true);
        verify(r.ok, r.error);
        const after = JSON.parse(r.text);
        compare(after.dock.autohide, true);
        compare(after.dock.pinned, ["foot", "x"]);
        compare(after.dock.magnification, 1.6);
        compare(after.extra, {a: [1, 2]});
        compare(after.appearance, "dark");
        verify(r.text.endsWith("\n"));
    }

    function test_setValueCreatesNestedObjects() {
        const r = Store.setValue('{"version":1}', "hotCorners.topRight", "apps");
        verify(r.ok, r.error);
        compare(JSON.parse(r.text), {version: 1, hotCorners: {topRight: "apps"}});
    }

    function test_freshFileGetsVersion() {
        for (const empty of ["", "  \n", null, undefined]) {
            const r = Store.setValue(empty, "appearance", "light");
            verify(r.ok, r.error);
            compare(JSON.parse(r.text), {version: 1, appearance: "light"});
        }
    }

    function test_malformedFileIsRefused() {
        for (const bad of ["{", "[1]", "null", "42", '{"version":1,}', "not json"]) {
            const r = Store.setValue(bad, "appearance", "light");
            verify(!r.ok, bad);
            verify(r.error !== "", bad);
            compare(r.text, "");
        }
        verify(!Store.setValue('{"version":2}', "appearance", "light").ok);
        verify(!Store.setValue('{"appearance":"dark"}', "appearance", "light").ok, "missing version in a non-empty file");
    }

    function test_invalidValueIsRefused() {
        const r = Store.setValue('{"version":1}', "material.transparency", 7);
        verify(!r.ok);
        compare(r.text, "");
    }

    function test_readFallsBackToDefaults() {
        const data = {version: 1, material: {transparency: 9, profile: "full"}, lock: "oops"};
        compare(Store.read(data, "material.transparency"), 0.25);
        compare(Store.read(data, "material.profile"), "full");
        compare(Store.read(data, "lock.idleMinutes"), 5);
        compare(Store.read({}, "hotCorners.topLeft"), "none");
    }

    function test_storeMergesAndWrites() {
        const t = makeStore('{"version":1,"dock":{"pinned":["foot"]},"keep":true}');
        compare(t.store.blocked, false);
        verify(t.store.set("material.transparency", 0.6));
        compare(t.backend.writes, 1);
        compare(t.store.value("material.transparency"), 0.6);
        const written = JSON.parse(t.backend.text);
        compare(written.keep, true);
        compare(written.dock.pinned, ["foot"]);
    }

    function test_storePicksUpExternalChange() {
        const t = makeStore('{"version":1}');
        compare(t.store.value("dock.autohide"), false);
        t.backend.text = '{"version":1,"dock":{"autohide":true}}';
        t.backend.fileChanged("/fake/grassfield.json");
        compare(t.store.value("dock.autohide"), true);
    }

    function test_storeNeverWritesMalformedFile() {
        const bad = '{"version":1,';
        const t = makeStore(bad);
        compare(t.store.blocked, true);
        verify(t.store.error !== "");
        verify(!t.store.set("appearance", "light"));
        compare(t.backend.writes, 0);
        compare(t.backend.text, bad);
        // The user fixes the file: writes work again.
        t.backend.text = '{"version":1}';
        t.backend.fileChanged("/fake/grassfield.json");
        compare(t.store.blocked, false);
        verify(t.store.set("appearance", "light"));
    }

    function test_storeCreatesMissingFile() {
        const t = makeStore("", false);
        compare(t.store.blocked, false);
        compare(t.store.value("appearance"), "dark");
        verify(t.store.set("appearance", "light"));
        compare(JSON.parse(t.backend.text), {version: 1, appearance: "light"});
    }

    function test_bindingsParse() {
        const lua = [
            '-- comment bind("A", "no", x)',
            'bind("SUPER + Q", "Close window", hl.dsp.window.close())',
            'bind("SUPER + W", "Close window", hl.dsp.window.close())',
            'bind("SUPER + W", "Close window", hl.dsp.window.close())',
            'bind("ALT + TAB", "Next window", a)',
            'bind("SUPER + mouse:272", "Move window", b, { mouse = true })',
            'bind("CTRL + code:" .. tostring(space + 9), "Switch to Space " .. space, c)',
            'bind("XF86AudioMute", "Mute", d)',
            'bind("SUPER + CTRL + F", "Say \\"hi\\"", e)',
            'local x = 1'
        ].join("\n");
        const list = Bindings.parse(lua);
        compare(list.length, 6);
        compare(list[0], {keys: "Super + Q", description: "Close window"});
        compare(list[1].keys, "Super + W");
        compare(list[2], {keys: "Alt + Tab", description: "Next window"});
        compare(list[3].keys, "Super + Left Mouse Button");
        compare(list[4], {keys: "XF86AudioMute", description: "Mute"});
        compare(list[5], {keys: "Super + Ctrl + F", description: 'Say "hi"'});
    }

    function test_bindingsParseRealFile() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/bindings.lua"), false);
        xhr.send();
        const list = Bindings.parse(xhr.responseText);
        verify(list.length > 20, "found " + list.length);
        verify(list.some(b => b.keys === "Super + Space" && b.description === "Search"));
    }

    function test_sysInfo() {
        const os = 'NAME="Omarchy"\nVERSION_ID="4.0.4"\nID=omarchy\n';
        compare(SysInfo.osReleaseValue(os, "ID"), "omarchy");
        compare(SysInfo.osLabel(os), "Omarchy 4.0.4");
        compare(SysInfo.osLabel(""), "");
        compare(SysInfo.cpu("processor\t: 0\nmodel name\t: AMD  Ryzen 7\nprocessor\t: 1\nmodel name\t: AMD Ryzen 7\n"), "AMD Ryzen 7 (2 threads)");
        compare(SysInfo.cpu(""), "");
        compare(SysInfo.memory("MemTotal:       16384000 kB\nMemFree: 1 kB\n"), "15.6 GiB");
        compare(SysInfo.memory(""), "");
        const pci = "00:02.0 VGA compatible controller: Intel Corporation Iris Xe (rev 0c)\n00:1f.3 Audio device: Intel Audio\n01:00.0 3D controller: NVIDIA Corp GA107\n";
        compare(SysInfo.gpus(pci), "Intel Corporation Iris Xe; NVIDIA Corp GA107");
        compare(SysInfo.gpus(""), "");
        compare(SysInfo.pacmanVersion("hyprland 0.56.2-1\n"), "0.56.2-1");
        compare(SysInfo.pacmanVersion(""), "");
    }
}
