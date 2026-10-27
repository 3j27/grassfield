import QtQuick
import QtTest
import "../../shell/saver/SaverModel.js" as SaverModel

// The screen saver's pure logic (ADR-0032, shell/saver/SaverModel.js): when it is armed, which saver, the clock's format,
// where the clock alone stands and what the wallpaper saver draws.
TestCase {
    name: "SaverModel"

    function test_armed() {
        verify(SaverModel.armed(600, false, false, false));
        verify(!SaverModel.armed(0, false, false, false), "a delay of 0 is never");
        verify(!SaverModel.armed(600, true, false, false), "never while locked");
        verify(!SaverModel.armed(600, false, true, false), "an application's inhibitor keeps it off");
        verify(!SaverModel.armed(600, false, false, true), "not while re-arming for a new delay");
        verify(!SaverModel.armed(SaverModel.MAX_SECONDS + 60, false, false, false), "beyond the settings' range");
        verify(SaverModel.armed(SaverModel.MAX_SECONDS, false, false, false));
    }

    function test_kindOf() {
        compare(SaverModel.kindOf("clock"), "clock");
        compare(SaverModel.kindOf("slideshow"), "slideshow");
        compare(SaverModel.kindOf("wallpaperClock"), "wallpaperClock");
        compare(SaverModel.kindOf("aerial"), "artwork", "an unknown kind shows the artwork");
        compare(SaverModel.kindOf(undefined), "artwork");
    }

    function test_folderOf() {
        compare(SaverModel.folderOf("", "/home/u/Pictures"), "/home/u/Pictures");
        compare(SaverModel.folderOf("/home/u/Photos", "/home/u/Pictures"), "/home/u/Photos");
        compare(SaverModel.folderOf(undefined, "/home/u/Pictures"), "/home/u/Pictures");
    }

    function test_clockFormat() {
        compare(SaverModel.clockFormat("h:mm AP"), "h:mm");
        compare(SaverModel.clockFormat("HH:mm"), "H:mm");
        compare(SaverModel.clockFormat(""), "H:mm");
    }

    // The clock alone stays inside the screen with its margin, and moves every minute.
    function test_clockPlace() {
        const seen = {};
        for (let minute = 29000000; minute < 29000120; minute++) {
            const p = SaverModel.clockPlace(minute, 1920, 1080, 400, 150, 48);
            verify(p.x >= 48 && p.x <= 1920 - 400 - 48, "x inside at minute " + minute);
            verify(p.y >= 48 && p.y <= 1080 - 150 - 48, "y inside at minute " + minute);
            seen[p.x + "," + p.y] = true;
        }
        verify(Object.keys(seen).length > 100, "two hours give more than 100 places");
        const a = SaverModel.clockPlace(29000000, 1920, 1080, 400, 150, 48);
        const b = SaverModel.clockPlace(29000001, 1920, 1080, 400, 150, 48);
        verify(a.x !== b.x || a.y !== b.y, "the next minute moves it");
        compare(SaverModel.clockPlace(29000000, 1920, 1080, 400, 150, 48), a, "the same minute, the same place");
        // A box larger than the screen stays at the margin.
        compare(SaverModel.clockPlace(5, 300, 200, 400, 300, 48), {x: 48, y: 48});
    }

    function test_backdrop() {
        compare(SaverModel.backdrop({file: "/c/prepared/a.jpg"}, {source: "folder"}), {kind: "picture", file: "/c/prepared/a.jpg", color: ""});
        compare(SaverModel.backdrop({file: ""}, {source: "color", color: "#336699"}), {kind: "color", file: "", color: "#336699"});
        compare(SaverModel.backdrop(undefined, {source: "builtin"}), {kind: "art", file: "", color: ""});
        compare(SaverModel.backdrop(undefined, undefined), {kind: "art", file: "", color: ""});
    }
}
