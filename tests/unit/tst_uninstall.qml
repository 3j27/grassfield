import QtQuick
import QtTest
import "../../ui/Grassfield/Ui/UninstallLogic.js" as Uninstall

// Deleting an app from the launcher and Files (ADR-0045): the Store's answer read fail-closed, what is removable and why not,
// the arguments handed to the Store and the jiggle. The only alert is the Store's (tst_storeoperations.qml).
TestCase {
    name: "Uninstall"

    readonly property string answer: JSON.stringify({version: 1, entries: {
            "gparted.desktop": {app: "gparted", name: "GParted", block: ""},
            "chromium.desktop": {app: "chromium", name: "Chromium", block: "omarchy"},
            "org.grassfield.Files.desktop": {app: "org.grassfield.Files", name: "Files", block: "grassfield"},
            "gcr-viewer.desktop": {app: "gcr", name: "Certificate Viewer", block: "dependency"},
            "linux-thing.desktop": {app: "x", name: "X", block: "system"},
            "com.obsproject.Studio.desktop": {app: "obs-studio", name: "OBS Studio", block: ""}
        }})

    function test_parseAndRemovable() {
        const map = Uninstall.parse(answer);
        verify(Uninstall.removable(map, "gparted"), "an id without .desktop");
        verify(Uninstall.removable(map, "gparted.desktop"), "an id with it");
        verify(Uninstall.removable(map, "com.obsproject.Studio"));
        verify(!Uninstall.removable(map, "chromium"), "Omarchy's own app");
        verify(!Uninstall.removable(map, "org.grassfield.Files"), "Grassfield's own app shows no x");
        verify(!Uninstall.removable(map, "gcr-viewer"), "pulled in by another app");
        verify(!Uninstall.removable(map, "linux-thing"), "the system");
        verify(!Uninstall.removable(map, "unknown"), "an app the Store does not know");
        verify(!Uninstall.removable(map, ""));
        verify(!Uninstall.removable(null, "gparted"));
    }

    function test_failClosed() {
        const bad = ["", "not json", "[]", "{}", '{"version":2,"entries":{}}', '{"version":1}', '{"version":1,"entries":[]}',
                     '{"version":1,"entries":{"a.desktop":{"app":1,"block":""}}}', '{"version":1,"entries":{"a.desktop":{"app":"a"}}}',
                     '{"version":1,"entries":{"../x.desktop":{"app":"a","name":"A","block":""}}}',
                     '{"version":1,"entries":{"a b.desktop":{"app":"a","name":"A","block":""}}}', null, undefined, 5];
        for (const text of bad)
            verify(Object.keys(Uninstall.parse(text)).length === 0, "refused: " + text);
        verify(Object.keys(Uninstall.parse("x".repeat(5 * 1024 * 1024))).length === 0, "too long");
        compare(Uninstall.entryKey("a/b"), "");
        compare(Uninstall.entryKey("x.desktop"), "x");
        compare(Uninstall.entryKey("a\nb"), "");
    }

    function test_reasons() {
        const map = Uninstall.parse(answer);
        compare(Uninstall.reason(map, "gparted"), "");
        compare(Uninstall.reason(map, "chromium"), "Part of Omarchy.");
        compare(Uninstall.reason(map, "org.grassfield.Files"), "Part of Grassfield.");
        compare(Uninstall.reason(map, "linux-thing"), "Part of the system.");
        compare(Uninstall.reason(map, "gcr-viewer"), "Installed with another app.");
        compare(Uninstall.reason(map, "nothing"), "The Store does not manage this app.");
        compare(Uninstall.reason({"x": {app: "x", name: "X", block: "protected"}}, "x"), "Removing it would also remove part of the system.");
    }

    function test_storeArguments() {
        compare(JSON.stringify(Uninstall.storeArguments("gparted")), '["--page","uninstall:gparted.desktop"]');
        compare(JSON.stringify(Uninstall.storeArguments("org.x.App.desktop")), '["--page","uninstall:org.x.App.desktop"]');
        compare(Uninstall.storeArguments("a b"), null);
        compare(Uninstall.storeArguments("--page"), null, "an option is never an id");
        compare(Uninstall.storeArguments(""), null);
    }

    function test_jiggle() {
        compare(Uninstall.jiggleAngle(100, 3, 0, 190), 0, "no amplitude: still");
        compare(Uninstall.jiggleAngle(100, 3, 2.2, 0), 0, "no period: still");
        let max = 0;
        for (let t = 0; t < 190; t += 5)
            max = Math.max(max, Math.abs(Uninstall.jiggleAngle(t, 7, 2.2, 190)));
        verify(max <= 2.2 + 1e-9 && max > 2.0, "rocks within the amplitude: " + max);
        // Periodic, and the icons do not rock together.
        fuzzyCompare(Uninstall.jiggleAngle(10, 4, 2.2, 190), Uninstall.jiggleAngle(200, 4, 2.2, 190), 1e-6);
        verify(Uninstall.jiggleAngle(10, 1, 2.2, 190) !== Uninstall.jiggleAngle(10, 2, 2.2, 190));
    }
}
