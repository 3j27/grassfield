pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.store

// Persistence round trip of grassfield.json through the real Quickshell FileView/JsonAdapter.
// Run by scripts/dev/test.sh: `qs -p tests/shell/settings_roundtrip` (offscreen). Prints
// "settings-roundtrip: PASS" and exits 0, or prints the failures and exits 1.
ShellRoot {
    id: root

    property string dir: "/tmp/gf-settings-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("settings-roundtrip: PASS");
            Qt.exit(0);
        } else {
            console.log("settings-roundtrip: FAIL " + failures.join(", "));
            Qt.exit(1);
        }
    }

    // Defaults and clamping first, then write, then read back with a second instance.
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
            root.finish();
        }
    }

    Timer {
        interval: 10000
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
        writer.flush();
    }
}
