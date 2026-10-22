pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.store

// Persistence of grassfield.json through the real Quickshell FileView/JsonAdapter.
// Run by scripts/dev/test.sh: `qs -p tests/shell/settings_roundtrip` (offscreen). Prints
// "settings-roundtrip: PASS" and exits 0, or prints the failures and exits 1.
// Phases: (1) defaults, clamping, write and read back; (2) a write keeps every schema key;
// (3) a malformed file is never overwritten; (4) out-of-range loaded values are clamped;
// (6) a file with an integer beyond 2^53 is never rewritten;
// (5) an external edit made right before a setter survives it, and unknown keys are preserved.
// Files live under $GRASSFIELD_TEST_TMP (test.sh removes it); the test also removes its own dir.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-settings-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    readonly property string dir: base + "/rt"
    readonly property string dirKeep: base + "/keep"
    readonly property string dirBad: base + "/bad"
    readonly property string dirRange: base + "/range"
    readonly property string badText: '{ "appearance": "light", oops'
    readonly property string keepText: '{"version":1,"appearance":"light","material":{"transparency":0.5,"profile":"full"},"accessibility":{"reduceTransparency":false,"reduceMotion":false},"dock":{"pinned":["a","b"],"magnification":1.2,"magnificationEnabled":true,"autohide":false},"windows":{"titlebarDoubleClick":"minimize"},"notifications":{"dnd":false,"previews":"always"},"lock":{"idleMinutes":17},"wallpaper":{"source":"folder","path":"/pics","outputs":[{"display":{"name":"X-1","model":"","serial":""},"fit":"tile"}]}}'
    readonly property string rangeText: '{"version":1,"icons":{"mode":"neon","tint":"#12345","folderColor":"red"},"appearance":"zzz","material":{"transparency":9,"profile":"nope"},"dock":{"pinned":[1,"","a"],"magnification":99},"windows":{"titlebarDoubleClick":"x"},"notifications":{"previews":"x"},"lock":{"idleMinutes":999},"pointer":{"size":7},"wallpaper":{"source":"file","path":"relative","color":"#ABCDEF","fit":7,"interval":"2s","shuffle":"yes","outputs":[{"bad":1}]}}'
    readonly property string dirMerge: base + "/merge"
    readonly property string mergeText: '{"version":1,"appearance":"dark","lock":{"idleMinutes":3},"futureKey":{"a":[1,2]},"notifications":{"dnd":false,"extra":"keep"}}'
    readonly property string mergeEdited: '{"version":1,"appearance":"light","lock":{"idleMinutes":42},"futureKey":{"a":[1,2]},"notifications":{"dnd":false,"extra":"keep"}}'
    readonly property string dirUnsafe: base + "/unsafe"
    readonly property string unsafeText: '{"version":1,"appearance":"dark","big":9007199254740993.0}'
    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function finish(): void {
        cleanup.running = true;
    }

    function report(): void {
        if (failures.length === 0) {
            console.log("settings-roundtrip: PASS");
            Qt.exit(0);
        } else {
            console.log("settings-roundtrip: FAIL " + failures.join(", "));
            Qt.exit(1);
        }
    }

    // Phase 1: defaults and clamping first, then write, then read back with a second instance.
    SettingsStore {
        id: writer
        configDir: root.dir
        saveDelay: 10
        onSaved: reader.configDir = root.dir
    }

    SettingsStore {
        id: reader
        saveDelay: 10
        onLoadedFile: {
            root.check("appearance", reader.data.appearance === "light");
            root.check("transparency", Math.abs(reader.data.material.transparency - 0.6) < 1e-9);
            root.check("reduceTransparency", reader.data.accessibility.reduceTransparency === true);
            root.check("reduceMotion", reader.data.accessibility.reduceMotion === true);
            root.check("autohide", reader.data.dock.autohide === true);
            root.check("magnification", Math.abs(reader.data.dock.magnification - 2.0) < 1e-9);
            root.check("magnificationEnabled", reader.data.dock.magnificationEnabled === false);
            root.check("pinned", reader.data.dock.pinned.join(",") === "foot,kitty");
            root.check("dnd", reader.data.notifications.dnd === true);
            root.check("previews", reader.data.notifications.previews === "never");
            root.check("version", reader.data.version === 1);
            root.check("icons mode", reader.data.icons.mode === "tinted" && reader.iconMode === "tinted");
            root.check("icons tint", reader.data.icons.tint === "#e5484d" && reader.iconTint === "#e5484d");
            root.check("icons folder colour", reader.data.icons.folderColor === "#e5484d" && reader.folderColor === "#e5484d");
            root.check("pointer size", reader.data.pointer.size === 48 && reader.pointerSize === 48);
            root.check("defaults kept: profile", reader.data.material.profile === "balanced");
            root.check("defaults kept: titlebar", reader.data.windows.titlebarDoubleClick === "zoom");
            root.check("defaults kept: idle", reader.data.lock.idleMinutes === 5);
            setup.running = true;
        }
    }

    // Phase 2 to 4 fixtures.
    Process {
        id: setup
        command: ["sh", "-c", 'mkdir -p "$1" "$2" "$3" && printf "%s" "$4" > "$1/grassfield.json" && printf "%s" "$5" > "$2/grassfield.json" && printf "%s" "$6" > "$3/grassfield.json"', "sh", root.dirKeep, root.dirBad, root.dirRange, root.keepText, root.badText, root.rangeText]
        onRunningChanged: {
            if (!running)
                keep.configDir = root.dirKeep;
        }
    }

    // Phase 2: a file holding every schema key; one setter must not drop the others.
    SettingsStore {
        id: keep
        saveDelay: 10
        property bool done: false
        onLoadedFile: {
            if (done)
                return;
            done = true;
            root.check("keep loaded profile", keep.data.material.profile === "full");
            // The adapter's QVariantList is not an Array: the outputs must survive it (review finding).
            root.check("keep wallpaper outputs through the adapter", keep.wallpaper.outputs.length === 1 && keep.wallpaper.outputs[0].fit === "tile" && keep.wallpaper.source === "folder");
            keep.setNotificationsDnd(true);
            keep.flush();
        }
        onSaved: readKeep.running = true
    }

    Process {
        id: readKeep
        command: ["cat", root.dirKeep + "/grassfield.json"]
        stdout: StdioCollector {
            onStreamFinished: {
                let o = {};
                try {
                    o = JSON.parse(text);
                } catch (e) {
                    root.check("keep parse", false);
                }
                root.check("keep dnd written", !!o.notifications && o.notifications.dnd === true);
                root.check("keep profile", !!o.material && o.material.profile === "full");
                root.check("keep transparency", !!o.material && o.material.transparency === 0.5);
                root.check("keep titlebar", !!o.windows && o.windows.titlebarDoubleClick === "minimize");
                root.check("keep idle", !!o.lock && o.lock.idleMinutes === 17);
                root.check("keep previews", !!o.notifications && o.notifications.previews === "always");
                root.check("keep pinned", !!o.dock && o.dock.pinned.join(",") === "a,b");
                bad.configDir = root.dirBad;
            }
        }
    }

    // Phase 3: a malformed file stays byte for byte; setters never write.
    SettingsStore {
        id: bad
        saveDelay: 10
        property bool done: false
        onLoadedFile: {
            if (done)
                return;
            done = true;
            root.check("bad blocked", bad.writeBlocked);
            bad.setAppearance("light");
            bad.setDockPinned(["x"]);
            bad.flush();
            badWait.start();
        }
    }

    Timer {
        id: badWait
        interval: 400
        onTriggered: readBad.running = true
    }

    Process {
        id: readBad
        command: ["cat", root.dirBad + "/grassfield.json"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.check("bad untouched", text === root.badText);
                range.configDir = root.dirRange;
            }
        }
    }

    // Phase 4: hand-edited garbage is clamped by the validated views.
    SettingsStore {
        id: range
        saveDelay: 10
        property bool done: false
        onLoadedFile: {
            if (done)
                return;
            done = true;
            root.check("range not blocked", !range.writeBlocked);
            root.check("range appearance", range.appearance === "dark");
            root.check("range transparency", range.transparency === 1);
            root.check("range profile", range.materialProfile === "balanced");
            root.check("range magnification", range.dockMagnification === 2.5);
            root.check("range pinned", range.dockPinned.join(",") === "a");
            root.check("range titlebar", range.titlebarDoubleClick === "zoom");
            root.check("range previews", range.notificationsPreviews === "unlocked");
            root.check("range idle", range.lockIdleMinutes === 240);
            root.check("range icon mode", range.iconMode === "default");
            root.check("range icon tint", range.iconTint === "accent");
            root.check("range folder colour", range.folderColor === "theme");
            root.check("range pointer size", range.pointerSize === 24);
            root.check("range wallpaper", range.wallpaper.source === "builtin" && range.wallpaper.path === "" && range.wallpaper.color === "#abcdef" && range.wallpaper.fit === "fill" && range.wallpaper.interval === "1h" && range.wallpaper.shuffle === true && range.wallpaper.outputs.length === 0);
            mergeSetup.running = true;
        }
    }

    // Phase 5: the store loads, the file is edited externally, then a setter runs at once.
    Process {
        id: mergeSetup
        command: ["sh", "-c", 'mkdir -p "$1" && printf "%s" "$2" > "$1/grassfield.json"', "sh", root.dirMerge, root.mergeText]
        onRunningChanged: {
            if (!running)
                merge.configDir = root.dirMerge;
        }
    }

    SettingsStore {
        id: merge
        saveDelay: 10
        property bool done: false
        onLoadedFile: {
            if (done)
                return;
            done = true;
            external.running = true;
        }
        onSaved: readMerge.running = true
    }

    Process {
        id: external
        command: ["sh", "-c", 'printf "%s" "$1" > "$2/grassfield.json"', "sh", root.mergeEdited, root.dirMerge]
        onRunningChanged: {
            if (!running) {
                // Immediately after the external write, before any reload could be relied on.
                merge.setNotificationsDnd(true);
                merge.flush();
            }
        }
    }

    Process {
        id: readMerge
        command: ["cat", root.dirMerge + "/grassfield.json"]
        stdout: StdioCollector {
            onStreamFinished: {
                let o = {};
                try {
                    o = JSON.parse(text);
                } catch (e) {
                    root.check("merge parse", false);
                }
                root.check("merge shell change", !!o.notifications && o.notifications.dnd === true);
                root.check("merge external appearance", o.appearance === "light");
                root.check("merge external idle", !!o.lock && o.lock.idleMinutes === 42);
                root.check("merge unknown key", !!o.futureKey && o.futureKey.a.join(",") === "1,2");
                root.check("merge unknown nested key", !!o.notifications && o.notifications.extra === "keep");
                unsafeSetup.running = true;
            }
        }
    }

    // Phase 6: a file JSON.parse cannot round-trip (integer beyond 2^53) is never rewritten.
    Process {
        id: unsafeSetup
        command: ["sh", "-c", 'mkdir -p "$1" && printf "%s" "$2" > "$1/grassfield.json"', "sh", root.dirUnsafe, root.unsafeText]
        onRunningChanged: {
            if (!running)
                unsafe.configDir = root.dirUnsafe;
        }
    }

    SettingsStore {
        id: unsafe
        saveDelay: 10
        property bool done: false
        onLoadedFile: {
            if (done)
                return;
            done = true;
            root.check("unsafe blocked", unsafe.writeBlocked);
            unsafe.setAppearance("light");
            root.check("unsafe keeps memory", unsafe.data.appearance === "light");
            unsafe.flush();
            unsafeWait.start();
        }
    }

    Timer {
        id: unsafeWait
        interval: 400
        onTriggered: readUnsafe.running = true
    }

    Process {
        id: readUnsafe
        command: ["cat", root.dirUnsafe + "/grassfield.json"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.check("unsafe untouched", text === root.unsafeText);
                root.finish();
            }
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.base]
        onRunningChanged: {
            if (!running)
                root.report();
        }
    }

    Timer {
        interval: 15000
        running: true
        onTriggered: {
            root.failures.push("timeout");
            root.finish();
        }
    }

    Component.onCompleted: {
        // Defaults when no file exists.
        check("default appearance", writer.data.appearance === "dark");
        check("default transparency", Math.abs(writer.data.material.transparency - 0.25) < 1e-9);
        check("default pinned", writer.data.dock.pinned.length === 3);
        check("default magnification", Math.abs(writer.data.dock.magnification - 1.6) < 1e-9);

        // Clamping and normalization.
        writer.setTransparency(7);
        check("clamp high", writer.data.material.transparency === 1);
        writer.setTransparency(-2);
        check("clamp low", writer.data.material.transparency === 0);
        writer.setAppearance("sepia");
        check("appearance normalized", writer.data.appearance === "dark");
        writer.setDockMagnification(9, true);
        check("magnification max", writer.data.dock.magnification === 2.5);
        writer.setDockMagnification(0.2, true);
        check("magnification min", writer.data.dock.magnification === 1);

        check("default dnd", writer.data.notifications.dnd === false);
        writer.setNotificationsPreviews("bogus");
        check("previews normalized", writer.data.notifications.previews === "unlocked");

        // Values written to disk.
        writer.setAppearance("light");
        writer.setTransparency(0.6);
        writer.setReduceTransparency(true);
        writer.setReduceMotion(true);
        writer.setDockAutohide(true);
        writer.setDockMagnification(2.0, false);
        writer.setDockPinned(["foot", "kitty"]);
        writer.setNotificationsDnd(true);
        writer.setNotificationsPreviews("never");
        // Icon appearance (ADR-0014): defaults, normalization, values written to disk.
        check("default icon mode", writer.iconMode === "default" && writer.data.icons.mode === "default");
        check("default icon tint", writer.iconTint === "accent");
        check("default folder colour", writer.folderColor === "theme" && writer.data.icons.folderColor === "theme");
        writer.setFolderColor("pink");
        check("folder colour normalized", writer.data.icons.folderColor === "theme");
        writer.setIconMode("sepia");
        check("icon mode normalized", writer.data.icons.mode === "default");
        writer.setIconTint("red");
        check("icon tint normalized", writer.data.icons.tint === "accent");
        writer.setIconMode("tinted");
        writer.setIconTint("#e5484d");
        writer.setFolderColor("#e5484d");
        // Pointer size: default, snapped to the 4 px step, kept in range, written to disk.
        check("default pointer size", writer.pointerSize === 24 && writer.data.pointer.size === 24);
        writer.setPointerSize(1000);
        check("pointer size clamped", writer.data.pointer.size === 96);
        writer.setPointerSize(51);
        check("pointer size snapped", writer.data.pointer.size === 52);
        writer.setPointerSize(48);
        // Pointer colours: the packaged theme's own by default; the Settings app writes them (the shell only reads).
        check("default pointer colours", writer.pointerOutlineColor === "#ffffff" && writer.pointerFillColor === "#000000" && writer.data.pointer.outlineColor === "#ffffff" && writer.data.pointer.fillColor === "#000000");
        // Wallpaper (ADR-0016): the defaults, complete, with the whole group in a fresh file; the shell never writes it.
        check("default wallpaper", writer.wallpaper.source === "builtin" && writer.wallpaper.path === "" && writer.wallpaper.color === "#000000" && writer.wallpaper.fit === "fill" && writer.wallpaper.interval === "1h" && writer.wallpaper.shuffle === true && writer.wallpaper.videoOnBattery === false && writer.wallpaper.outputs.length === 0 && writer.data.wallpaper.interval === "1h");
        writer.flush();
    }
}
