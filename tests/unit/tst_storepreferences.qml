import QtQuick
import QtTest
import "../../apps/store/qml/Preferences.js" as Preferences

// The Store's own keys of grassfield.json (apps/store/qml/Preferences.js, ADR-0037 SD20): set as the Settings app sets its
// keys, every other key kept in its order, never a malformed, unsafe or newer file written, never a value the contract
// refuses; and the read-set-write path through the backend's two calls.
TestCase {
    name: "StorePreferences"

    function test_freshFile() {
        const r = Preferences.setValue("", "store.sources.aur", true);
        verify(r.ok);
        compare(JSON.parse(r.text), {version: 1, store: {sources: {aur: true}}});
        verify(r.text.endsWith("\n"));
        compare(Preferences.setValue("  \n", "store.screenshots", false).text, '{\n  "version": 1,\n  "store": {\n    "screenshots": false\n  }\n}\n');
    }

    function test_otherKeysKeptInTheirOrder() {
        const text = '{"version":1,"dock":{"size":48},"store":{"screenshots":true,"sources":{"flathub":false}},"zeta":[1,2]}';
        const r = Preferences.setValue(text, "store.sources.aur", true);
        verify(r.ok);
        const data = JSON.parse(r.text);
        compare(Object.keys(data), ["version", "dock", "store", "zeta"]);
        compare(data.store, {screenshots: true, sources: {flathub: false, aur: true}});
        compare(data.zeta, [1, 2]);
        // A value in the key's way that is not an object is replaced by one.
        compare(JSON.parse(Preferences.setValue('{"version":1,"store":3}', "store.sources.aur", false).text).store, {sources: {aur: false}});
    }

    function test_neverWritten() {
        for (const text of ["{", "[1]", "null", '"x"', '{"version":2}', '{"version":"1"}', '{"store":{}}', '{"version":1,"a":1,"a":2}',
                            '{"version":1,"n":9007199254740993}']) {
            const r = Preferences.setValue(text, "store.sources.aur", true);
            verify(!r.ok, text);
            compare(r.text, "", text);
            verify(r.error !== "", text);
        }
        // The contract's rule for the key: a boolean only.
        verify(!Preferences.setValue("", "store.sources.aur", "yes").ok);
        verify(!Preferences.setValue("", "store.sources.aur", 1).ok);
    }

    // The read-set-write path: an unreadable file is never replaced, a refused one is left as it is.
    function test_setThroughTheBackend() {
        const backend = {
            file: {exists: true, ok: true, text: '{"version":1,"dock":{"size":48}}\n'},
            written: null,
            readConfig() { return this.file; },
            writeConfig(text) { this.written = text; return ""; }
        };
        compare(Preferences.set(backend, "store.sources.aur", true), "");
        compare(JSON.parse(backend.written), {version: 1, dock: {size: 48}, store: {sources: {aur: true}}});

        backend.written = null;
        backend.file = {exists: true, ok: false, text: ""};
        compare(Preferences.set(backend, "store.sources.aur", true), "unreadable");
        compare(backend.written, null);
        backend.file = {exists: true, ok: true, text: '{"version":2}'};
        verify(Preferences.set(backend, "store.sources.aur", true) !== "");
        compare(backend.written, null);
        backend.file = {exists: false, ok: false, text: ""};
        compare(Preferences.set(backend, "store.screenshots", false), "");
        compare(JSON.parse(backend.written), {version: 1, store: {screenshots: false}});
    }
}
