import QtQuick
import QtTest
import Grassfield.Ui

// Wallpaper settings and rules (ADR-0016, ui/Grassfield/Ui/WallpaperConfig.js): validation, defaults, display matching,
// per-display resolution, the carousel order, the pause policy, the helper's argument vectors and the failure ids.
// Schema parity lives in tst_settingsstore.
TestCase {
    name: "Wallpaper"

    readonly property var panel: ({name: "eDP-1", model: "LGD", serial: "123"})
    readonly property var panelMoved: ({name: "DP-3", model: "LGD", serial: "123"})
    readonly property var other: ({name: "HDMI-A-1", model: "", serial: ""})

    // The module, the schema and the default file agree (Store.js's literals are checked against the schema by
    // tst_settingsstore).
    function test_schemaParity() {
        function read(rel) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl(rel), false);
            xhr.send();
            return JSON.parse(xhr.responseText);
        }
        const props = read("../../config/schema/grassfield.schema.json").properties.wallpaper.properties;
        compare(props.source.enum, WallpaperConfig.SOURCES);
        compare(props.fit.enum, WallpaperConfig.FITS);
        compare(props.interval.enum, WallpaperConfig.INTERVAL_NAMES);
        compare(Object.keys(props).sort(), Object.keys(WallpaperConfig.WALLPAPER_DEFAULTS).sort());
        compare(Object.keys(props.outputs.items.properties).sort(), ["color", "display", "fit", "interval", "path", "shuffle", "source"]);
        compare(read("../../config/defaults/grassfield.json").wallpaper, WallpaperConfig.WALLPAPER_DEFAULTS);
    }

    function test_defaults() {
        const n = WallpaperConfig.normalize(undefined);
        compare(n.source, "builtin");
        compare(n.path, "");
        compare(n.color, "#000000");
        compare(n.fit, "fill");
        compare(n.interval, "1h");
        compare(n.shuffle, true);
        compare(n.videoOnBattery, false);
        compare(n.outputs, []);
        for (const raw of [null, 5, "x", [], true])
            compare(WallpaperConfig.normalize(raw), n, String(raw));
    }

    function test_invalidFieldsReadAsDefaults() {
        const n = WallpaperConfig.normalize({source: "online", path: "rel/x.jpg", color: "red", fit: 3, interval: "2s", shuffle: "yes", videoOnBattery: 1, outputs: "x"});
        compare(n.source, "builtin");
        compare(n.path, "");
        compare(n.color, "#000000");
        compare(n.fit, "fill");
        compare(n.interval, "1h");
        compare(n.shuffle, true);
        compare(n.videoOnBattery, false);
        compare(n.outputs, []);
    }

    function test_sourceNeedsPath() {
        compare(WallpaperConfig.normalize({source: "file"}).source, "builtin");
        compare(WallpaperConfig.normalize({source: "folder", path: "relative"}).source, "builtin");
        compare(WallpaperConfig.normalize({source: "video", path: ""}).source, "builtin");
        compare(WallpaperConfig.normalize({source: "file", path: "/a/b.jpg"}).source, "file");
        compare(WallpaperConfig.normalize({source: "color", color: "#ABCDEF"}).color, "#abcdef");
        compare(WallpaperConfig.normalize({source: "color"}).source, "color", "colour needs no path");
    }

    function test_videoFit() {
        compare(WallpaperConfig.normalize({source: "video", path: "/v.mp4", fit: "tile"}).fit, "fill");
        compare(WallpaperConfig.normalize({source: "video", path: "/v.mp4", fit: "fit"}).fit, "fit");
        compare(WallpaperConfig.normalize({source: "file", path: "/v.jpg", fit: "tile"}).fit, "tile");
    }

    function test_pathRules() {
        compare(WallpaperConfig.pathProblem("/home/u/a.jpg"), "");
        compare(WallpaperConfig.pathProblem("/home/u/é ü 日本.jpg"), "");
        compare(WallpaperConfig.pathProblem(""), "empty");
        compare(WallpaperConfig.pathProblem("a.jpg"), "not-absolute");
        compare(WallpaperConfig.pathProblem("-rf"), "not-absolute");
        compare(WallpaperConfig.pathProblem(5), "not-a-string");
        compare(WallpaperConfig.pathProblem(null), "not-a-string");
        compare(WallpaperConfig.pathProblem("/a\nb"), "control-characters");
        compare(WallpaperConfig.pathProblem("/a\u0000b"), "control-characters");
        compare(WallpaperConfig.pathProblem("/a\u007fb"), "control-characters");
        compare(WallpaperConfig.pathProblem("/a‮b"), "control-characters", "bidi override");
        compare(WallpaperConfig.pathProblem("/" + "a".repeat(4095)), "");
        compare(WallpaperConfig.pathProblem("/" + "a".repeat(4096)), "too-long");
        // The limit is in bytes, not characters.
        compare(WallpaperConfig.pathProblem("/" + "é".repeat(2048)), "too-long");
        compare(WallpaperConfig.pathProblem("/" + "é".repeat(2047)), "");
        compare(WallpaperConfig.pathProblem("/" + "😀".repeat(1025)), "too-long");
    }

    function test_colorRules() {
        verify(WallpaperConfig.validColor("#a1B2c3"));
        verify(!WallpaperConfig.validColor("#a1b2c"));
        verify(!WallpaperConfig.validColor("a1b2c3"));
        verify(!WallpaperConfig.validColor("#a1b2c3 "));
        verify(!WallpaperConfig.validColor(0xa1b2c3));
    }

    function test_outputsValidation() {
        compare(WallpaperConfig.outputsProblem([]), "");
        compare(WallpaperConfig.outputsProblem([{display: panel, fit: "tile"}]), "");
        verify(WallpaperConfig.outputsProblem("x") !== "");
        verify(WallpaperConfig.outputsProblem([{}]) !== "", "display is required");
        verify(WallpaperConfig.outputsProblem([{display: {name: "", model: "m", serial: ""}}]) !== "", "no identity");
        verify(WallpaperConfig.outputsProblem([{display: panel, bogus: 1}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: {name: "a", model: "", serial: "", extra: 1}}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel, fit: "zoom"}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel, path: "rel"}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel, shuffle: "no"}]) !== "");
        verify(WallpaperConfig.outputsProblem([{display: panel}, {display: panelMoved}]) !== "", "same display twice");
        const many = [];
        for (let i = 0; i < 17; i++)
            many.push({display: {name: "o" + i, model: "", serial: ""}});
        compare(WallpaperConfig.outputsProblem(many.slice(0, 16)), "");
        compare(WallpaperConfig.outputsProblem(many), "too-many");
    }

    function test_normalizeOutputsDropsBadEntries() {
        const many = [];
        for (let i = 0; i < 20; i++)
            many.push({display: {name: "o" + i, model: "", serial: ""}, extra: "dropped?"});
        compare(WallpaperConfig.normalizeOutputs(many).length, 0, "entries with unknown keys are dropped");
        const good = [];
        for (let i = 0; i < 20; i++)
            good.push({display: {name: "o" + i, model: "", serial: ""}});
        compare(WallpaperConfig.normalizeOutputs(good).length, 16, "capped at 16");
        const mixed = [{display: panel, fit: "tile", bogus: 1}, {display: panel, fit: "fit"}, {display: other, source: "color"}, 7, null];
        const out = WallpaperConfig.normalizeOutputs(mixed);
        compare(out.length, 2, "the first is invalid (unknown key); the second and the third are kept; 7 and null are dropped");
        compare(out[0].display.name, "eDP-1");
        compare(out[0].fit, "fit");
    }

    function test_displayIdentity() {
        verify(WallpaperConfig.sameDisplay(panel, panelMoved), "model and serial win over the connector");
        verify(!WallpaperConfig.sameDisplay(panel, {name: "eDP-1", model: "LGD", serial: "999"}));
        verify(WallpaperConfig.sameDisplay(other, {name: "HDMI-A-1", model: "X", serial: ""}), "no serial: the connector name");
        verify(!WallpaperConfig.sameDisplay(other, {name: "HDMI-A-2", model: "", serial: ""}));
    }

    function test_resolve() {
        const cfg = {source: "folder", path: "/pics", fit: "fit", interval: "5m", outputs: [{display: panel, source: "color", color: "#112233"}, {display: other, fit: "tile", shuffle: false}]};
        const all = WallpaperConfig.resolve(cfg, {name: "Z", model: "", serial: ""});
        compare(all.source, "folder");
        compare(all.fit, "fit");
        verify(!("outputs" in all));
        const p = WallpaperConfig.resolve(cfg, panelMoved);
        compare(p.source, "color");
        compare(p.color, "#112233");
        compare(p.fit, "fit", "omitted fields come from the top level");
        const o = WallpaperConfig.resolve(cfg, other);
        compare(o.source, "folder");
        compare(o.fit, "tile");
        compare(o.shuffle, false);
        // An override can make a source without a path fall back to the artwork.
        const f = WallpaperConfig.resolve({outputs: [{display: panel, source: "file"}]}, panel);
        compare(f.source, "builtin");
    }

    function test_withOutput() {
        let list = WallpaperConfig.withOutput([], panel, {fit: "tile"});
        compare(list.length, 1);
        compare(list[0].fit, "tile");
        list = WallpaperConfig.withOutput(list, panelMoved, {color: "#010203"});
        compare(list.length, 1, "same display: replaced, not added");
        compare(list[0].fit, "tile");
        compare(list[0].color, "#010203");
        list = WallpaperConfig.withOutput(list, other, {source: "color"});
        compare(list.length, 2);
        list = WallpaperConfig.withOutput(list, panel, null);
        compare(list.length, 1);
        compare(list[0].display.name, "HDMI-A-1");
        const full = [];
        for (let i = 0; i < 16; i++)
            full.push({display: {name: "o" + i, model: "", serial: ""}});
        compare(WallpaperConfig.withOutput(full, {name: "new", model: "", serial: ""}, {fit: "fit"}).length, 16, "overflow leaves the list as it was");
        // The result always validates.
        compare(WallpaperConfig.outputsProblem(list), "");
    }

    function test_intervals() {
        compare(WallpaperConfig.intervalMs("login"), 0);
        compare(WallpaperConfig.intervalMs("5s"), 5000);
        compare(WallpaperConfig.intervalMs("1m"), 60000);
        compare(WallpaperConfig.intervalMs("1h"), 3600000);
        compare(WallpaperConfig.intervalMs("1d"), 86400000);
        compare(WallpaperConfig.intervalMs("bogus"), 3600000, "unknown reads as the default");
        compare(WallpaperConfig.INTERVAL_NAMES.length, 8);
        for (const name of WallpaperConfig.INTERVAL_NAMES)
            verify(name in WallpaperConfig.INTERVALS, name);
    }

    function names(n) {
        const l = [];
        for (let i = 0; i < n; i++)
            l.push("/p/" + (i < 10 ? "0" : "") + i + ".jpg");
        return l;
    }

    function test_orderWithoutShuffleIsByName() {
        const files = ["/p/b.jpg", "/p/a.jpg", "/p/C.jpg"];
        compare(WallpaperConfig.cycleOrder(files, false, 7), ["/p/C.jpg", "/p/a.jpg", "/p/b.jpg"]);
        compare(files[0], "/p/b.jpg", "the input is not modified");
    }

    function test_shuffleIsStableForASeedAndAPermutation() {
        const files = names(12);
        const a = WallpaperConfig.cycleOrder(files, true, 42);
        const b = WallpaperConfig.cycleOrder(files.slice().reverse(), true, 42);
        compare(a, b, "the same seed gives the same order whatever the listing order");
        compare(a.slice().sort(), files, "a permutation");
        verify(JSON.stringify(a) !== JSON.stringify(WallpaperConfig.cycleOrder(files, true, 43)), "another seed, another order");
        verify(JSON.stringify(a) !== JSON.stringify(files), "actually shuffled");
    }

    function test_advanceNoRepeatUntilAllShown() {
        const files = names(7);
        let state = {seed: 5, index: 0, last: ""};
        let seen = [];
        let lastFile = "";
        for (let cycle = 0; cycle < 4; cycle++) {
            seen = [];
            for (let i = 0; i < files.length; i++) {
                const r = WallpaperConfig.advance(files, true, state, null);
                verify(seen.indexOf(r.file) < 0, "no repeat inside a cycle: " + r.file);
                verify(r.file !== lastFile || i > 0 || files.length < 2, "no repeat across the cycle border");
                seen.push(r.file);
                lastFile = r.file;
                state = r.state;
            }
            compare(seen.slice().sort(), files);
        }
    }

    function test_advanceDeterministicAfterRestart() {
        const files = names(9);
        let state = {seed: 3, index: 0, last: ""};
        const first = [];
        for (let i = 0; i < 4; i++) {
            const r = WallpaperConfig.advance(files, true, state, null);
            first.push(r.file);
            state = r.state;
        }
        // A restart restores {seed, index, last} from the state file and continues the same cycle.
        const saved = JSON.parse(JSON.stringify(state));
        const cont = WallpaperConfig.advance(files, true, saved, null).file;
        const full = WallpaperConfig.cycleOrder(files, true, 3, "");
        compare(first, full.slice(0, 4));
        compare(cont, full[4]);
    }

    function test_advanceSkipsBadAndHandlesEmpty() {
        const files = ["/p/a.jpg", "/p/b.jpg", "/p/c.jpg"];
        const bad = {"/p/b.jpg": true};
        let state = {seed: 1, index: 0, last: ""};
        const seen = [];
        for (let i = 0; i < 4; i++) {
            const r = WallpaperConfig.advance(files, false, state, bad);
            seen.push(r.file);
            state = r.state;
        }
        compare(seen, ["/p/a.jpg", "/p/c.jpg", "/p/a.jpg", "/p/c.jpg"]);
        compare(WallpaperConfig.advance(files, false, state, {"/p/a.jpg": true, "/p/b.jpg": true, "/p/c.jpg": true}).file, "", "every file failed");
        compare(WallpaperConfig.advance([], true, undefined, null).file, "");
        // A garbage state reads as a fresh one.
        compare(WallpaperConfig.advance(files, false, {seed: "x", index: null, last: 5}, null).file, "/p/a.jpg");
    }

    function test_advanceNewFilesJoinNextCycle() {
        let files = ["/p/a.jpg", "/p/b.jpg"];
        let state = {seed: 1, index: 0, last: ""};
        let r = WallpaperConfig.advance(files, false, state, null);
        compare(r.file, "/p/a.jpg");
        files = ["/p/a.jpg", "/p/aa.jpg", "/p/b.jpg"];
        r = WallpaperConfig.advance(files, false, r.state, null);
        compare(r.file, "/p/aa.jpg", "name order: a new file sorts into place (shuffle off)");
    }

    function test_playbackState() {
        const base = {locked: false, fullscreen: false, idle: false, onBattery: false, videoOnBattery: false, reduceMotion: false, profile: "balanced"};
        function st(over) {
            return WallpaperConfig.playbackState(Object.assign({}, base, over)).state;
        }
        compare(st({}), "play");
        compare(st({locked: true}), "pause");
        compare(st({fullscreen: true}), "pause");
        compare(st({idle: true}), "settle");
        compare(st({idle: true, reduceMotion: true}), "pause", "Reduce Motion pauses at once");
        compare(st({reduceMotion: true}), "pause");
        compare(st({profile: "reduced"}), "pause");
        compare(st({profile: "full"}), "play");
        compare(st({onBattery: true}), "pause");
        compare(st({onBattery: true, videoOnBattery: true}), "play");
        compare(st({onBattery: false, videoOnBattery: true}), "play");
        compare(st({onBattery: true, idle: true}), "pause", "battery wins over idle settle");
        compare(st({locked: true, idle: true, fullscreen: true}), "pause");
        compare(WallpaperConfig.playbackState(Object.assign({}, base, {locked: true})).reason, "locked");
        compare(WallpaperConfig.playbackState(base).reason, "");
    }

    function test_argumentVectorsHaveNoInjection() {
        const ok = WallpaperConfig.prepareArgs("/usr/lib/grassfield/grassfield-wallpaper", "/home/u/p.jpg", 1920, 1080, "fill", "#AABBCC", "/c/out");
        compare(ok, ["/usr/lib/grassfield/grassfield-wallpaper", "prepare", "--size", "1920x1080", "--fit", "fill", "--color", "#aabbcc", "--out", "/c/out", "--", "/home/u/p.jpg"]);
        // The source comes after "--": whatever it looks like, it is a path.
        compare(WallpaperConfig.prepareArgs("h", "/--size=1x1", 10, 10, "fill", "#000000", "/o")[11], "/--size=1x1");
        // Not a valid input, so no process: a path starting with "-", a relative path, a newline, a bad fit or colour.
        compare(WallpaperConfig.prepareArgs("h", "-rf", 10, 10, "fill", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "rel.jpg", 10, 10, "fill", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a\nb.jpg", 10, 10, "fill", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "zoom", "#000000", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "fill", "black", "/o"), null);
        compare(WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "fill", "#000000", "-o"), null);
        // Sizes are clamped.
        compare(WallpaperConfig.sizeArg(0, -5), "1x1");
        compare(WallpaperConfig.sizeArg(1e9, 100000), "16384x16384");
        compare(WallpaperConfig.sizeArg(1919.6, 1080.2), "1920x1080");
        compare(WallpaperConfig.thumbArgs("h", "/a.jpg", 5000, "/o"), ["h", "thumb", "--width", "1024", "--out", "/o", "--", "/a.jpg"]);
        compare(WallpaperConfig.thumbArgs("h", "-a.jpg", 320, "/o"), null);
        compare(WallpaperConfig.listArgs("h", "/pics", 10000), ["h", "list", "--max", "10000", "--", "/pics"]);
        compare(WallpaperConfig.listArgs("h", "pics", 10000), null);
    }

    function test_failureIds() {
        compare(WallpaperConfig.reasonOf(0), "");
        compare(WallpaperConfig.reasonOf(3), "not-found");
        compare(WallpaperConfig.reasonOf(4), "not-regular");
        compare(WallpaperConfig.reasonOf(5), "too-large");
        compare(WallpaperConfig.reasonOf(6), "too-large");
        compare(WallpaperConfig.reasonOf(7), "unreadable");
        compare(WallpaperConfig.reasonOf(8), "unsupported");
        compare(WallpaperConfig.reasonOf(9), "timeout");
        compare(WallpaperConfig.reasonOf(127), "helper-missing");
        compare(WallpaperConfig.reasonOf(139), "failed", "a crash of the helper (SIGSEGV)");
        compare(WallpaperConfig.reasonOf(-1), "failed");
    }

    function test_stripContrast() {
        const black = WallpaperConfig.stripContrast(0, 0);
        fuzzyCompare(black.white, 21, 1e-9);
        const white = WallpaperConfig.stripContrast(1, 1);
        fuzzyCompare(white.black, 21, 1e-9);
        // A split strip: white text is limited by its lightest part, black text by its darkest part.
        const split = WallpaperConfig.stripContrast(0, 1);
        fuzzyCompare(split.white, 1, 1e-9);
        fuzzyCompare(split.black, 1, 1e-9);
        // The crossover of the two tones is around 0.179.
        const mid = WallpaperConfig.stripContrast(0.179, 0.179);
        verify(Math.abs(mid.white - mid.black) < 0.05);
    }
}
