import QtQuick
import QtTest
import Grassfield.Ui

// The generated settings contract (ui/Grassfield/Ui/SettingsContract.js, from the schema by scripts/dev/gen-settings.py):
// the shared vectors (tests/fixtures/settings-vectors.json), the clamp semantics every reader shares, and the bounds the
// Dock's tokens repeat.
TestCase {
    name: "SettingsContract"

    function readJson(relative) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relative), false);
        xhr.send();
        return JSON.parse(xhr.responseText);
    }

    // The parsed document {a: {b: value}} for a dotted path.
    function dataFor(path, value) {
        const parts = path.split(".");
        const root = {};
        let node = root;
        for (let i = 0; i < parts.length - 1; i++) {
            node[parts[i]] = {};
            node = node[parts[i]];
        }
        node[parts[parts.length - 1]] = value;
        return root;
    }

    function test_sharedVectors() {
        const vectors = readJson("../fixtures/settings-vectors.json").vectors;
        verify(vectors.length > 40);
        for (const v of vectors) {
            const data = v.absent === true ? {} : dataFor(v.path, v.stored);
            const want = v.default === true ? SettingsContract.DEFAULTS[v.path] : v.read;
            compare(SettingsContract.read(data, v.path), want, v.name);
            if (v.valid !== undefined)
                compare(SettingsContract.validate(v.path, v.stored) === "", v.valid, v.name + " (valid)");
            // Normalising is stable: a value that was read reads as itself.
            compare(SettingsContract.normalize(v.path, want), want, v.name + " (stable)");
        }
    }

    function test_readThroughANonObject() {
        compare(SettingsContract.read({wallpaper: 3}, "wallpaper.fit"), SettingsContract.DEFAULTS["wallpaper.fit"]);
        compare(SettingsContract.read({}, "dock.size"), SettingsContract.DEFAULTS["dock.size"]);
        compare(SettingsContract.read(null, "dock.size"), SettingsContract.DEFAULTS["dock.size"]);
    }

    function test_unknownKey() {
        verify(SettingsContract.validate("no.such.key", 1) !== "");
        compare(SettingsContract.normalize("no.such.key", 1), undefined);
    }

    function test_everyDefaultIsValidAndStable() {
        for (const path in SettingsContract.RULES) {
            compare(SettingsContract.validate(path, SettingsContract.DEFAULTS[path]), "", path);
            compare(SettingsContract.normalize(path, SettingsContract.DEFAULTS[path]), SettingsContract.DEFAULTS[path], path);
        }
        compare(Object.keys(SettingsContract.RULES).sort(), Object.keys(SettingsContract.DEFAULTS).sort());
        compare(SettingsContract.VERSION, 1);
    }

    function test_defaultsFileHoldsTheDefaults() {
        const file = readJson("../../config/defaults/grassfield.json");
        for (const path in SettingsContract.DEFAULTS)
            compare(SettingsContract.read(file, path), SettingsContract.DEFAULTS[path], path);
        compare(file.version, SettingsContract.VERSION);
    }

    // Tokens repeat the Dock's size bounds (the shell clamps with them): the schema is the source.
    function test_dockBoundsMatchTheTokens() {
        compare(SettingsContract.RULES["dock.size"].min, Tokens.dockSizeMin);
        compare(SettingsContract.RULES["dock.size"].max, Tokens.dockSizeMax);
    }
}
