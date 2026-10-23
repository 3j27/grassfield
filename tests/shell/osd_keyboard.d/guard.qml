pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.services
import qs.osd

// Body of tests/shell/osd_keyboard.sh (REQ-OSD-NG-d1a): the keyboard backlight OSD. Offscreen, GRASSFIELD_DEV=1, no hardware:
// the kind and its icon, level clamping, bad input, the keyboard keys with and without a backlight device (a device is
// faked by setting the service's properties once its own lookup has finished), and that the dev session never changes the
// backlight (setKbdLevel refuses, the OSD shows the current level).
ShellRoot {
    id: root

    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Timer {
        interval: 1200
        running: true
        onTriggered: root.run()
    }

    function run(): void {
        check("the test runs in a dev session", Brightness.devSession);

        // The kind and its icon.
        Osd.showValue("keyboard", 0.5, false);
        check("kind keyboard", Osd.kind === "keyboard");
        check("icon keyboard", Osd.iconName === "keyboard");
        check("level kept", Math.abs(Osd.level - 0.5) < 1e-9);
        check("shown", Osd.shown);

        // Clamping and bad input.
        Osd.showValue("keyboard", 7, false);
        check("level clamped to 1", Osd.level === 1);
        Osd.showValue("keyboard", -3, false);
        check("level clamped to 0", Osd.level === 0);
        Osd.showValue("keyboard", 0.25, false);
        Osd.showValue("keyboard", NaN, false);
        check("NaN ignored", Math.abs(Osd.level - 0.25) < 1e-9);
        Osd.showValue("bogus", 0.3, false);
        check("an unknown kind reads as volume", Osd.kind === "volume");
        Osd.showValue("brightness", 0.3, false);
        check("brightness keeps its icon", Osd.iconName === "sun");

        // Keys without a backlight device: nothing shows.
        Osd.hide();
        Brightness.kbdDevice = "";
        check("no device, not available", !Brightness.kbdAvailable);
        Osd.keyboardStep("up");
        check("no device: the key shows nothing", !Osd.shown);

        // With a (fake) device in a dev session: the backlight is not changed, the OSD shows the current level.
        Brightness.kbdDevice = "test::kbd_backlight";
        Brightness.kbdMax = 8;
        Brightness.kbdValue = 4;
        check("fake device available", Brightness.kbdAvailable);
        Osd.hide();
        Osd.keyboardStep("up");
        check("dev: the key shows the OSD", Osd.shown && Osd.kind === "keyboard");
        check("dev: it shows the current level", Math.abs(Osd.level - 0.5) < 1e-9);
        check("dev: the value is untouched", Brightness.kbdValue === 4);
        Osd.hide();
        Osd.keyboardStep("down");
        check("dev: down shows too", Osd.shown && Osd.kind === "keyboard");
        Osd.hide();
        Osd.keyboardStep("sideways");
        check("an unknown direction shows nothing", !Osd.shown);

        // The first backlight value read is not a user action.
        Brightness.kbdValue = 5;
        Brightness.kbdValue = 6;
        finish();
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("PASS: osd_keyboard");
            Qt.exit(0);
        } else {
            console.log("FAIL: osd_keyboard " + failures.join(", "));
            Qt.exit(1);
        }
    }
}
