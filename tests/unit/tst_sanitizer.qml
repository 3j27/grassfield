import QtQuick
import QtTest
import "../../shell/notifications/Sanitizer.js" as Sanitizer

TestCase {
    name: "Sanitizer"

    function test_allowedTagsKept() {
        compare(Sanitizer.sanitize("a <b>bold</b> <i>it</i> <u>un</u>"), "a <b>bold</b> <i>it</i> <u>un</u>");
        compare(Sanitizer.sanitize("<B>Up</B>"), "<b>Up</b>");
    }

    function test_scriptAndUnknownTagsStripped() {
        compare(Sanitizer.sanitize("x<script>alert(1)</script>y"), "xalert(1)y");
        compare(Sanitizer.sanitize("<span style=\"color:red\">t</span><font size=9>f</font>"), "tf");
        compare(Sanitizer.sanitize("<p onclick=\"x\">p</p>"), "p");
    }

    function test_linkShownAsText() {
        compare(Sanitizer.sanitize("see <a href=\"https://example.org/x\">docs</a>!"), "see docs (https://example.org/x)!");
        compare(Sanitizer.sanitize("<a href=\"https://e.org\">https://e.org</a>"), "https://e.org");
        verify(Sanitizer.sanitize("<a href=\"x\">y</a>").indexOf("<a") === -1);
    }

    function test_imagesDropped() {
        compare(Sanitizer.sanitize("a<img src=\"file:///etc/passwd\">b"), "ab");
        compare(Sanitizer.sanitize("<img src=\"x\" alt=\"logo\">"), "logo");
    }

    function test_textIsEscaped() {
        compare(Sanitizer.sanitize("1 < 2 & 3 > 2"), "1 &lt; 2 &amp; 3 &gt; 2");
        compare(Sanitizer.sanitize("&lt;b&gt;not bold&lt;/b&gt;"), "&lt;b&gt;not bold&lt;/b&gt;");
        compare(Sanitizer.sanitize("&amp;amp;"), "&amp;amp;");
    }

    function test_unbalancedTagsAreBalanced() {
        compare(Sanitizer.sanitize("<b>open"), "<b>open</b>");
        compare(Sanitizer.sanitize("close</b>"), "close");
        compare(Sanitizer.sanitize("<b><i>x</b>y"), "<b><i>x</i></b>y");
    }

    function test_newlinesAndBreaks() {
        compare(Sanitizer.sanitize("a\nb<br/>c<br>d"), "a<br>b<br>c<br>d");
    }

    function test_nonStringAndLength() {
        compare(Sanitizer.sanitize(undefined), "");
        compare(Sanitizer.sanitize(null), "");
        compare(Sanitizer.sanitize("x".repeat(10000)).length, 4000);
    }

    // Tag-like input must stay linear (was O(n^2): 250 ms per 4000 characters).
    function test_tagLikeInputIsLinear() {
        const inputs = ["<a".repeat(2000), "<a \"".repeat(1000), "<a '\"".repeat(800), "<".repeat(4000), "<b ".repeat(1300) + ">", "<a '>".repeat(660), "<a \">".repeat(660)];
        for (const input of inputs) {
            const t0 = Date.now();
            Sanitizer.sanitize(input);
            const ms = Date.now() - t0;
            console.log("sanitize " + input.length + " chars: " + ms + " ms");
            // Generous bound for loaded CI/dev machines: the quadratic version took ~885 ms on this input.
            verify(ms < 150, "sanitize took " + ms + " ms");
        }
    }

    // 1000 valid tags: every tag produces output, so this is slower than the failing scans above.
    function test_denseValidMarkup() {
        const t0 = Date.now();
        compare(Sanitizer.sanitize("<b>x</b>".repeat(500)).length, 500 * 8);
        verify(Date.now() - t0 < 100);
    }

    function test_longTagIsText() {
        compare(Sanitizer.sanitize("<b " + "x".repeat(600) + ">hi"), "&lt;b " + "x".repeat(600) + "&gt;hi");
    }

    function test_plain() {
        compare(Sanitizer.plain("<b>1</b> &amp; <i>2</i><br>3"), "1 & 2\n3");
    }
}
