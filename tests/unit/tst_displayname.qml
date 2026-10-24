import QtQuick
import QtTest
import "../../ui/Grassfield/Ui/DisplayName.js" as DisplayName

// GF-105: the one helper every file name goes through before it is shown (the controls are written as escapes here so that
// this source never holds a bidi control itself).
TestCase {
    name: "DisplayName"

    function test_bidiControlsAreWrittenOut() {
        compare(DisplayName.text("evil‮fdp.exe"), "evil<U+202E>fdp.exe");
        compare(DisplayName.text("a⁦b⁩c"), "a<U+2066>b<U+2069>c");
        compare(DisplayName.text("‪‫‬‭"), "<U+202A><U+202B><U+202C><U+202D>");
    }

    function test_breaksBecomeTheReturnSymbol() {
        compare(DisplayName.text("two\nlines"), "two⏎lines");
        compare(DisplayName.text("a\r\n\r\nb"), "a⏎b");
    }

    function test_everythingElseStays() {
        compare(DisplayName.text("say \"hi\" \\ there"), "say \"hi\" \\ there");
        compare(DisplayName.text("marks‎kept"), "marks‎kept");
        compare(DisplayName.text("Résumé"), "Résumé");
        compare(DisplayName.text(undefined), "");
        compare(DisplayName.text(null), "");
        compare(DisplayName.text(12), "12");
    }
}
