import QtQuick
import QtTest
import "../../shell/platform/UpdateNotice.js" as UpdateNotice

// GF-083: "Log out to finish updating". Unknown versions never show it; a known difference does.
TestCase {
    name: "UpdateNotice"

    function test_theVersionFileIsItsFirstLine() {
        compare(UpdateNotice.fromFile("1.0.0-rc1\n"), "1.0.0-rc1");
        compare(UpdateNotice.fromFile("1.0.0rc1\nextra\n"), "1.0.0rc1");
        compare(UpdateNotice.fromFile(""), "");
        compare(UpdateNotice.fromFile("not a version\n"), "");
        compare(UpdateNotice.fromFile(undefined), "");
    }

    function test_thePluginVersionIsReadFromTheReplyWhenThereIsOne() {
        compare(UpdateNotice.fromReply('{"v":"gfc/1","type":"capabilities","features":["a","b"],"version":"1.0.0rc1"}'), "1.0.0rc1");
        // An older plugin: no version field.
        compare(UpdateNotice.fromReply('{"v":"gfc/1","type":"capabilities","features":["a"]}'), "");
        compare(UpdateNotice.fromReply('{"v":"gfc/1","type":"error"}'), "");
        compare(UpdateNotice.fromReply("Invalid dispatcher"), "");
        compare(UpdateNotice.fromReply(""), "");
        compare(UpdateNotice.fromReply('{"type":"capabilities","version":42}'), "");
        compare(UpdateNotice.fromReply('{"type":"capabilities","version":"a b"}'), "");
        compare(UpdateNotice.fromReply('{"type":"capabilities","version":"' + "9".repeat(80) + '"}'), "");
    }

    function test_spellingOfTheSameVersionIsNotADifference() {
        verify(UpdateNotice.same("1.0.0-rc1", "1.0.0rc1"));
        verify(UpdateNotice.same("1.0.0RC1", "1.0.0-rc1"));
        verify(!UpdateNotice.same("1.0.0-rc1", "1.0.0-rc2"));
        verify(!UpdateNotice.same("", ""));
    }

    function test_aKnownDifferenceShowsTheNotice() {
        // plugin older than the package
        verify(UpdateNotice.pending("1.0.1", "1.0.1", "1.0.0"));
        // shell older than the package (the file changed after the shell started)
        verify(UpdateNotice.pending("1.0.1", "1.0.0", ""));
        verify(UpdateNotice.pending("1.0.1", "1.0.0", "1.0.1"));
    }

    function test_nothingKnownMeansNoNotice() {
        verify(!UpdateNotice.pending("1.0.0", "1.0.0", "1.0.0"));
        verify(!UpdateNotice.pending("1.0.0-rc1", "1.0.0rc1", "1.0.0-rc1"));
        // No VERSION file (an older package): everything unknown.
        verify(!UpdateNotice.pending("", "", "1.0.0"));
        // A plugin without the field: only the shell is compared.
        verify(!UpdateNotice.pending("1.0.1", "1.0.1", ""));
        verify(!UpdateNotice.pending("1.0.1", "", ""));
        verify(!UpdateNotice.pending(undefined, undefined, undefined));
    }
}
