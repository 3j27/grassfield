import QtQuick
import QtTest
import "../../shell/menubar/ClockFormat.js" as Clock

// Menu bar clock options (macOS Clock: date, day of the week, 24-hour time, seconds).
TestCase {
    name: "ClockFormat"

    function test_autoKeepsTheLocalePattern() {
        compare(Clock.timePattern("HH:mm", "auto", false), "HH:mm");
        compare(Clock.timePattern("h:mm AP", "auto", false), "h:mm AP");
        compare(Clock.timePattern("", "auto", false), "HH:mm");
    }

    function test_hourFormatOverridesTheLocale() {
        compare(Clock.timePattern("h:mm AP", "24", false), "HH:mm");
        compare(Clock.timePattern("HH:mm", "12", false), "h:mm AP");
        compare(Clock.timePattern("HH:mm", "bogus", false), "HH:mm");
    }

    function test_secondsFollowTheMinutes() {
        compare(Clock.timePattern("HH:mm", "auto", true), "HH:mm:ss");
        compare(Clock.timePattern("h:mm AP", "auto", true), "h:mm:ss AP");
        compare(Clock.timePattern("x", "12", true), "h:mm:ss AP");
        compare(Clock.timePattern("h:mm AP", "24", true), "HH:mm:ss");
    }

    function test_quotedTextIsNotTheMinutes() {
        compare(Clock.timePattern("HH 'min' mm", "auto", true), "HH 'min' mm:ss");
        compare(Clock.timePattern("HH 'h'", "auto", true), "HH 'h':ss");
    }

    function test_amPmCanGo() {
        compare(Clock.timePattern("h:mm AP", "auto", false, false), "h:mm");
        compare(Clock.timePattern("x", "12", true, false), "h:mm:ss");
        compare(Clock.timePattern("x", "12", false, true), "h:mm AP");
        compare(Clock.timePattern("HH:mm", "auto", false, false), "HH:mm");
        compare(Clock.timePattern("'at' h:mm AP", "auto", false, false), "'at' h:mm");
    }

    function test_flashSeparators() {
        compare(Clock.flash("13:46:05", false), "13:46:05");
        compare(Clock.flash("13:46:05", true), "13 46 05");
    }

    function test_dateWhenSpaceAllows() {
        compare(Clock.dateFits("always", {a: true}, 900, 100), true);
        compare(Clock.dateFits("never", {}, 1, 100), false);
        compare(Clock.dateFits("auto", {}, 90, 100), true);
        compare(Clock.dateFits("auto", {tray0: true}, 90, 100), false);
        compare(Clock.dateFits("auto", {}, 120, 100), false);
    }

    function test_dateKinds() {
        compare(Clock.dateKind(true, true), "both");
        compare(Clock.dateKind(false, true), "day");
        compare(Clock.dateKind(true, false), "date");
        compare(Clock.dateKind(false, false), "none");
    }

    function test_join() {
        compare(Clock.join("Sun 25 Oct", "13:46"), "Sun 25 Oct 13:46");
        compare(Clock.join("", "13:46"), "13:46");
    }
}
