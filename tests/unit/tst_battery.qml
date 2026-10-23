import QtQuick
import QtTest
import "../../shell/services/BatteryLogic.js" as Logic

// Quick Settings Battery module logic: percentage, time remaining, power source, Low Power Mode.
TestCase {
    name: "BatteryLogic"

    function test_percent() {
        compare(Logic.percent(0.874), 87);
        compare(Logic.percent(1.4), 100);
        compare(Logic.percent(-1), 0);
        compare(Logic.percent(NaN), 0);
        compare(Logic.percent(undefined), 0);
    }

    function test_duration() {
        compare(Logic.duration(4320), "1:12");
        compare(Logic.duration(540), "0:09");
        compare(Logic.duration(0), "");
        compare(Logic.duration(-5), "");
        compare(Logic.duration(undefined), "");
    }

    function test_source() {
        compare(Logic.source(1, false), "adapter");
        compare(Logic.source(4, true), "adapter");
        compare(Logic.source(2, true), "battery");
        compare(Logic.source(2, false), "battery");
        compare(Logic.source(0, false), "adapter");
        compare(Logic.source(0, true), "battery");
    }

    function test_status() {
        compare(Logic.status(4, 1, 1).kind, "full");
        compare(Logic.status(1, 0, 3600).time, "1:00");
        compare(Logic.status(1, 0, 0).kind, "charging");
        compare(Logic.status(2, 7200, 0).time, "2:00");
        compare(Logic.status(2, 0, 0).time, "");
        compare(Logic.status(0, 1, 1).kind, "idle");
    }

    function test_lowPower() {
        verify(Logic.lowPower(0));
        verify(!Logic.lowPower(1));
        verify(!Logic.lowPower(2));
        compare(Logic.profileFor(true), 0);
        compare(Logic.profileFor(false), 1);
    }

    function test_icon() {
        compare(Logic.iconName(1), "battery-charging");
        compare(Logic.iconName(2), "battery");
    }
}
