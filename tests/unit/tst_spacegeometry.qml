import QtQuick
import QtTest
import "../../shell/platform/SpaceGeometry.js" as SG

// The output size a desktop miniature is scaled against: logical pixels, on every output scale.
TestCase {
    name: "SpaceGeometry"

    function test_aScreenAnswersInLogicalPixels() {
        const screens = [{name: "DP-1", width: 2560, height: 1440}, {name: "HDMI-A-1", width: 1920, height: 1080}];
        compare(SG.logicalSize(screens, "DP-1", {width: 3840, height: 2160, lastIpcObject: {scale: 1.5}}), {w: 2560, h: 1440});
    }

    function test_withoutAScreenTheMonitorPixelsAreDividedByTheScale() {
        compare(SG.logicalSize([], "DP-1", {width: 3840, height: 2160, lastIpcObject: {scale: 1.5}}), {w: 2560, h: 1440});
        compare(SG.logicalSize([], "DP-1", {width: 3840, height: 2160, lastIpcObject: {scale: 2}}), {w: 1920, h: 1080});
        compare(SG.logicalSize(null, "DP-1", {width: 1920, height: 1080, lastIpcObject: {scale: 1}}), {w: 1920, h: 1080});
        // No scale reported: scale 1.
        compare(SG.logicalSize([], "DP-1", {width: 1920, height: 1080}), {w: 1920, h: 1080});
    }

    function test_aWindowKeepsItsShareOfTheScreenOnAScaledOutput() {
        // A 1280 x 720 logical window on a 3840 x 2160 px output at scale 2 (1920 x 1080 logical) fills two thirds of its width.
        const size = SG.logicalSize([], "DP-1", {width: 3840, height: 2160, lastIpcObject: {scale: 2}});
        fuzzyCompare(1280 / size.w, 2 / 3, 0.001);
        // The pixel size would have halved it.
        fuzzyCompare(1280 / 3840, 1 / 3, 0.001);
    }

    function test_unknownOutput() {
        compare(SG.logicalSize([], "DP-9", null), {w: 0, h: 0});
        compare(SG.logicalSize([{name: "DP-1", width: 0, height: 0}], "DP-1", {width: 0, height: 0}), {w: 0, h: 0});
    }
}
