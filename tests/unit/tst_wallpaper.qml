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
        compare(n.online, {provider: "commons"});
        compare(n.outputs, []);
        for (const raw of [null, 5, "x", [], true])
            compare(WallpaperConfig.normalize(raw), n, String(raw));
    }

    function test_invalidFieldsReadAsDefaults() {
        const n = WallpaperConfig.normalize({source: "apod", path: "rel/x.jpg", color: "red", fit: 3, interval: "2s", shuffle: "yes", videoOnBattery: 1, online: {provider: "apod"}, outputs: "x"});
        compare(n.source, "builtin");
        compare(n.path, "");
        compare(n.color, "#000000");
        compare(n.fit, "fill");
        compare(n.interval, "1h");
        compare(n.shuffle, true);
        compare(n.videoOnBattery, false);
        compare(n.online, {provider: "commons"});
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

    // The JSON adapter hands out a QVariantList as a sequence that is not an Array (review finding: the shell dropped
    // wallpaper.outputs). A stand-in with a length and indices; the real adapter path is in tests/shell/settings_roundtrip.
    function makeSeq(items) {
        // A prototype of its own, like the adapter's sequence: not Object.prototype, not Array.prototype.
        const o = Object.create({});
        o.length = items.length;
        for (let i = 0; i < items.length; i++)
            o[i] = items[i];
        return o;
    }

    function test_arrayLikeOutputs() {
        const like = makeSeq([{display: panel, fit: "tile"}, {display: other, source: "color"}]);
        verify(!Array.isArray(like));
        compare(WallpaperConfig.outputsProblem(like), "");
        compare(WallpaperConfig.normalizeOutputs(like).length, 2);
        const cfg = {source: "folder", path: "/pics", outputs: like};
        compare(WallpaperConfig.resolve(cfg, panelMoved).fit, "tile");
        compare(WallpaperConfig.resolve(cfg, other).source, "color");
        compare(WallpaperConfig.normalize(cfg).outputs.length, 2);
        const huge = makeSeq([]);
        huge.length = 1e9;
        compare(WallpaperConfig.outputsProblem(huge), "too-many");
        compare(WallpaperConfig.normalizeOutputs(huge).length, 0, "a hostile length reads at most a bounded number of items");
        const negative = makeSeq([]);
        negative.length = -1;
        compare(WallpaperConfig.outputsProblem(negative), "not-an-array");
        const fractional = makeSeq([]);
        fractional.length = 1.5;
        compare(WallpaperConfig.outputsProblem(fractional), "not-an-array");
        compare(WallpaperConfig.outputsProblem(makeSeq([{}])), "entry 0: display");
    }

    // A JSON object is not a list, whatever keys it has (the schema says array): {"length": 1, "0": {...}} reads as none.
    function test_aPlainObjectWithALengthIsNotAList() {
        const hostile = {length: 1, 0: {display: panel, fit: "tile"}};
        compare(WallpaperConfig.outputsProblem(hostile), "not-an-array");
        compare(WallpaperConfig.normalizeOutputs(hostile).length, 0);
        compare(WallpaperConfig.normalize({source: "color", outputs: hostile}).outputs.length, 0);
        compare(WallpaperConfig.outputsProblem({}), "not-an-array");
        compare(WallpaperConfig.outputsProblem(Object.create(null)), "not-an-array");
        compare(WallpaperConfig.outputsProblem("abc"), "not-an-array");
        compare(WallpaperConfig.outputsProblem(7), "not-an-array");
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

    // Review finding: "login" advanced on every restart of the shell. It advances only for a new login.
    function test_keepPictureAfterARestart() {
        const files = ["/p/a.jpg", "/p/b.jpg"];
        const now = 1000000;
        // Timed interval: kept until it elapsed.
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: now - 1000}, 3600000, now, "", files, null), "/p/b.jpg");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: now - 3600001}, 3600000, now, "", files, null), "");
        // Login: kept for the same login (compositor instance), advanced for another one or an unknown one.
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1, loginKey: "inst-1"}, 0, now, "inst-1", files, null), "/p/b.jpg", "a shell restart in the same login");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1, loginKey: "inst-1"}, 0, now, "inst-2", files, null), "", "a new login");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1, loginKey: "inst-1"}, 0, now, "", files, null), "", "unknown login key");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: 1}, 0, now, "inst-1", files, null), "", "no key stored");
        // Never kept: vanished, failed this session, no state.
        compare(WallpaperConfig.keepPicture({last: "/p/gone.jpg", changedAt: now}, 3600000, now, "", files, null), "");
        compare(WallpaperConfig.keepPicture({last: "/p/b.jpg", changedAt: now}, 3600000, now, "", files, {"/p/b.jpg": true}), "");
        compare(WallpaperConfig.keepPicture(null, 3600000, now, "", files, null), "");
        compare(WallpaperConfig.keepPicture({last: 5, changedAt: now}, 3600000, now, "", files, null), "");
    }

    function test_prepareArgsKeepFiles() {
        const args = WallpaperConfig.prepareArgs("h", "/a.jpg", 10, 10, "fill", "#000000", "/o", 24, 1000, ["/o/x.jpg", "rel.jpg", "/o/y\nz.jpg", "/o/y.jpg"]);
        compare(args, ["h", "prepare", "--size", "10x10", "--fit", "fill", "--color", "#000000", "--out", "/o", "--strip-rows", "24", "--cache-max-bytes", "1000", "--keep", "/o/x.jpg", "--keep", "/o/y.jpg", "--", "/a.jpg"]);
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

    // Cases both implementations (this module and apps/settings/qml/Store.js, tst_settingsstore) must answer alike.
    function test_sharedRuleCases() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/wallpaper-rules.json"), false);
        xhr.send();
        const cases = JSON.parse(xhr.responseText);
        verify(cases.paths.length > 10);
        for (const c of cases.paths)
            compare(WallpaperConfig.pathProblem(c[0]), c[1], JSON.stringify(c[0]).substring(0, 60));
        for (const c of cases.outputs)
            compare(WallpaperConfig.outputsProblem(c[0]) === "", c[1], JSON.stringify(c[0]).substring(0, 100));
    }

    function test_devGuard() {
        const repo = "/w/repo";
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev/wallpapers/a.jpg", true, repo), "");
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev", true, repo), "");
        compare(WallpaperConfig.sourceProblem("/home/u/Pictures/a.jpg", true, repo), "outside-dev");
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev/../secret.jpg", true, repo), "outside-dev", "dot-dot is resolved first");
        compare(WallpaperConfig.sourceProblem("/w/repo/.devious/a.jpg", true, repo), "outside-dev", "a sibling with the same prefix");
        compare(WallpaperConfig.sourceProblem("/w/repo/.dev//wallpapers/./a.jpg", true, repo), "");
        compare(WallpaperConfig.sourceProblem("/home/u/Pictures/a.jpg", false, repo), "", "outside dev every absolute path is allowed");
        compare(WallpaperConfig.sourceProblem("rel.jpg", false, repo), "not-absolute");
        compare(WallpaperConfig.normalizePath("/a/b/../c//d/."), "/a/c/d");
        compare(WallpaperConfig.normalizePath("/.."), "/");
        compare(WallpaperConfig.normalizePath("a"), "");
        verify(WallpaperConfig.isUnder("/a/b", "/a"));
        verify(!WallpaperConfig.isUnder("/ab", "/a"));
    }

    function test_environmentPaths() {
        const dev = {dev: true, repoRoot: "/w/repo", home: "/home/u", xdgCache: "", picturesDir: ""};
        compare(WallpaperConfig.toolPath(dev), "/w/repo/.dev/build/grassfield-wallpaper");
        compare(WallpaperConfig.cacheRoot(dev), "/w/repo/.dev/cache/wallpapers");
        compare(WallpaperConfig.picturesRoot(dev), "/w/repo/.dev/wallpapers");
        const prod = {dev: false, repoRoot: "/w/repo", home: "/home/u", xdgCache: "", picturesDir: ""};
        compare(WallpaperConfig.toolPath(prod), "/usr/lib/grassfield/grassfield-wallpaper");
        compare(WallpaperConfig.cacheRoot(prod), "/home/u/.cache/grassfield/wallpapers");
        compare(WallpaperConfig.cacheRoot(Object.assign({}, prod, {xdgCache: "/x/cache"})), "/x/cache/grassfield/wallpapers");
        compare(WallpaperConfig.picturesRoot(Object.assign({}, prod, {picturesDir: "/home/u/Bilder"})), "/home/u/Bilder");
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

    // ---- online daily pictures (ADR-0016 step 2) ----

    function test_onlineSource() {
        compare(WallpaperConfig.normalize({source: "online"}).source, "online", "needs no path");
        compare(WallpaperConfig.normalize({source: "online", online: {provider: "commons"}}).online, {provider: "commons"});
        compare(WallpaperConfig.normalize({source: "online", online: "x"}).online, {provider: "commons"});
        compare(WallpaperConfig.normalize({source: "online", online: {provider: "apod"}}).online, {provider: "commons"}, "an unknown provider reads as the default");
        compare(WallpaperConfig.resolve({source: "online"}, panel).source, "online");
        compare(WallpaperConfig.resolve({source: "online"}, panel).provider, "commons");
        // Off by default, and a display can opt out or in on its own.
        compare(WallpaperConfig.normalize(undefined).source, "builtin");
        verify(!WallpaperConfig.onlineWanted(undefined));
        verify(!WallpaperConfig.onlineWanted({source: "folder", path: "/p"}));
        verify(WallpaperConfig.onlineWanted({source: "online"}));
        verify(WallpaperConfig.onlineWanted({source: "builtin", outputs: [{display: panel, source: "online"}]}));
        verify(WallpaperConfig.onlineWanted({source: "online", outputs: [{display: panel, source: "builtin"}]}), "other displays may still use it");
        compare(WallpaperConfig.resolve({source: "online", outputs: [{display: panel, source: "file", path: "/a.jpg"}]}, panel).source, "file");
        compare(WallpaperConfig.outputsProblem([{display: panel, source: "online"}]), "");
    }

    function test_onlineHelperArguments() {
        const out = "/home/u/.cache/grassfield/wallpapers/online/commons";
        compare(WallpaperConfig.fetchArgs("/usr/lib/grassfield/grassfield-wallpaper", "commons", "2026-10-22", out, "fr", ""), ["/usr/lib/grassfield/grassfield-wallpaper", "fetch", "commons", "--date", "2026-10-22", "--out", out, "--lang", "fr"]);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22", out, "en", "http://127.0.0.1:8123").slice(-2), ["--base-url", "http://127.0.0.1:8123"]);
        compare(WallpaperConfig.fetchArgs("/h", "apod", "2026-10-22", out, "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22x", out, "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "--out", out, "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22", "relative", "en", ""), null);
        compare(WallpaperConfig.fetchArgs("/h", "commons", "2026-10-22", out, "de; rm", ""), null);
        compare(WallpaperConfig.latestArgs("/h", "commons", out), ["/h", "latest", "commons", "--out", out]);
        compare(WallpaperConfig.latestArgs("/h", "commons", "x"), null);
        compare(WallpaperConfig.reasonOf(11), "network");
        compare(WallpaperConfig.reasonOf(12), "skipped");
        compare(WallpaperConfig.reasonOf(13), "bad-response");
        verify(WallpaperConfig.onlineSkips(12));
        verify(WallpaperConfig.onlineSkips(5));
        verify(!WallpaperConfig.onlineSkips(11));
        verify(!WallpaperConfig.onlineSkips(9));
    }

    function test_onlineDates() {
        const t = Date.UTC(2026, 9, 22, 0, 9, 59);
        compare(WallpaperConfig.onlineDate(t), "2026-10-21", "before 00:10 UTC the day before");
        compare(WallpaperConfig.onlineDate(t + 1000), "2026-10-22", "from 00:10 UTC");
        compare(WallpaperConfig.onlineDate(Date.UTC(2026, 9, 22, 23, 59, 59)), "2026-10-22");
        compare(WallpaperConfig.onlineDate(Date.UTC(2027, 0, 1, 0, 5)), "2026-12-31", "across a year");
        verify(isNaN(WallpaperConfig.utcDayStart("2026-02-30")));
        verify(isNaN(WallpaperConfig.utcDayStart("x")));
    }

    function test_onlineScheduleFirstFetchIsImmediate() {
        const now = Date.UTC(2026, 9, 22, 3, 0);
        // Nothing cached and the day's slot (00:10 + rand * 6 h) is later: still due at once.
        const s = WallpaperConfig.onlineSchedule({}, now, false, 0.99);
        verify(s.due);
        compare(s.date, "2026-10-22");
        // A picture is cached: wait for the slot.
        const w = WallpaperConfig.onlineSchedule({}, now, true, 0.99);
        verify(!w.due);
        compare(w.at, Date.UTC(2026, 9, 22, 0, 10) + Math.floor(0.99 * 6 * 3600000));
        verify(w.at > now);
        const d = WallpaperConfig.onlineSchedule({}, now, true, 0.0);
        verify(d.due, "slot at 00:10 has passed at 03:00");
        compare(d.at, Date.UTC(2026, 9, 22, 0, 10));
    }

    function test_onlineSlotIsStableForTheDay() {
        const now = Date.UTC(2026, 9, 22, 9, 0);
        const a = WallpaperConfig.onlineSchedule({}, now, true, 0.5);
        // Persisted, then evaluated again with another random number: the slot does not move.
        const b = WallpaperConfig.onlineSchedule(a.state, now + 60000, true, 0.01);
        compare(b.at, a.at);
        // The next day picks a new one.
        const c = WallpaperConfig.onlineSchedule(a.state, Date.UTC(2026, 9, 23, 1, 0), true, 0.25);
        compare(c.date, "2026-10-23");
        compare(c.at, Date.UTC(2026, 9, 23, 0, 10) + Math.floor(0.25 * 6 * 3600000));
        // The window is 00:10 to 06:10 UTC.
        for (const r of [0, 0.3, 0.7, 0.999999, 1, 5, -1])
            verify(WallpaperConfig.onlineSchedule({}, Date.UTC(2026, 9, 22, 12), true, r).at <= Date.UTC(2026, 9, 22, 6, 10));
    }

    function test_onlineOneSuccessfulFetchPerDay() {
        const now = Date.UTC(2026, 9, 22, 9, 0);
        const st = WallpaperConfig.onlineAfter({}, now, "2026-10-22", "ok");
        const s = WallpaperConfig.onlineSchedule(st, now + 3600000, true, 0.0);
        verify(!s.due);
        compare(s.at, Date.UTC(2026, 9, 23, 0, 10), "looks again when the next day starts");
        // A skip (licence) ends the day too.
        verify(!WallpaperConfig.onlineSchedule(WallpaperConfig.onlineAfter({}, now, "2026-10-22", "skipped"), now, true, 0).due);
        // The next day it is due again once its slot has come.
        verify(WallpaperConfig.onlineSchedule(st, Date.UTC(2026, 9, 23, 7, 0), true, 0.0).due);
    }

    function test_onlineBackoff() {
        const t0 = Date.UTC(2026, 9, 22, 9, 0);
        let st = WallpaperConfig.onlineAfter({}, t0, "2026-10-22", "network");
        compare(st.failures, 1);
        compare(st.retryAt, t0 + 3600000, "1 h after the first failure");
        verify(!WallpaperConfig.onlineSchedule(st, t0 + 3599000, true, 0).due);
        verify(WallpaperConfig.onlineSchedule(st, t0 + 3600000, true, 0).due);
        const t1 = t0 + 3600000;
        st = WallpaperConfig.onlineAfter(st, t1, "2026-10-22", "network");
        compare(st.failures, 2);
        compare(st.retryAt, t1 + 3 * 3600000, "3 h after the second");
        verify(!WallpaperConfig.onlineSchedule(st, t1 + 3 * 3600000 - 1000, true, 0).due);
        const t2 = t1 + 3 * 3600000;
        st = WallpaperConfig.onlineAfter(st, t2, "2026-10-22", "network");
        compare(st.failures, 3);
        // Then the next day: not due for the rest of today, whatever the clock says.
        const s = WallpaperConfig.onlineSchedule(st, t2 + 5 * 3600000, true, 0);
        verify(!s.due);
        compare(s.at, Date.UTC(2026, 9, 23, 0, 10));
        // The next day starts with a clean slate.
        verify(WallpaperConfig.onlineSchedule(st, Date.UTC(2026, 9, 23, 7, 0), true, 0).due);
        // Success resets everything.
        const ok = WallpaperConfig.onlineAfter(st, t2, "2026-10-22", "ok");
        compare(ok.failures, 0);
        compare(ok.retryAt, 0);
        // Nothing cached does not bypass the backoff.
        verify(!WallpaperConfig.onlineSchedule(WallpaperConfig.onlineAfter({}, t0, "2026-10-22", "network"), t0 + 60000, false, 0.5).due);
    }

    function test_onlineStateFromAnything() {
        for (const raw of [null, 5, "x", [], {failures: "many", done: 7, retryAt: -1, slotAt: "x", failDate: "2026-99-99"}]) {
            const st = WallpaperConfig.onlineStateOf(raw);
            compare(st.done, "");
            compare(st.failures, 0);
            compare(st.retryAt, 0);
            compare(st.failDate, "");
        }
        compare(WallpaperConfig.onlineStateOf({failures: 99}).failures, 3);
        compare(WallpaperConfig.onlineStateOf({done: "2026-10-22"}).done, "2026-10-22");
    }
}
