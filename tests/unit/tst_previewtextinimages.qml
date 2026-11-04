pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"
import "../../apps/preview/qml/TextInImages.js" as TextInImages

// Select Text in Images (ADR-0045 OC-2, docs/specs/preview.md P13): the pure part (apps/preview/qml/TextInImages.js: the
// languages, tesseract's TSV, the selection in reading order, the copied text, the QR codes and which of them are links),
// the reading of one image at a time (ImageText.qml with a mock backend: once per image, cancelled when it changes, silent
// when a tool is missing), and the image view over it (ImageView.qml: the I-beam, a drag that selects, Copy, the context
// menu and the QR chips).
TestCase {
    id: test
    name: "PreviewTextInImages"
    width: 800
    height: 600
    visible: true
    when: windowShown

    // A 400 x 200 picture: "Hello world" on the first line, "again" on the second (one paragraph), "Total 42" in a second
    // block; a noise word, a line of noise, a malformed row and a row of another page are left out.
    readonly property string tsv: [
        "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext",
        "1\t1\t0\t0\t0\t0\t0\t0\t400\t200\t-1\t",
        "2\t1\t1\t0\t0\t0\t20\t20\t200\t60\t-1\t",
        "3\t1\t1\t1\t0\t0\t20\t20\t200\t60\t-1\t",
        "4\t1\t1\t1\t1\t0\t20\t20\t200\t20\t-1\t",
        "5\t1\t1\t1\t1\t1\t20\t20\t60\t20\t95.5\tHello",
        "5\t1\t1\t1\t1\t2\t90\t20\t60\t20\t91.0\tworld",
        "5\t1\t1\t1\t1\t3\t160\t20\t10\t20\t12.0\t~",
        "5\t1\t1\t1\t2\t1\t20\t50\t50\t20\t88.25\tagain",
        "5\t1\t2\t1\t1\t1\t300\t20\t30\t20\t35.0\tnz",
        "5\t1\t2\t1\t1\t2\t340\t20\t30\t20\t40.0\tzz",
        "5\t1\t3\t1\t1\t1\t20\t150\t50\t20\t90\tTotal",
        "5\t1\t3\t1\t1\t2\t80\t150\t30\t20\t90\t42",
        "5\tx\t3\t1\t1\t3\t80\t150\t30\t20\t90\tbroken",
        "5\t2\t1\t1\t1\t1\t20\t20\t60\t20\t95\tother page",
        ""
    ].join("\n")

    // ---- the pure part -------------------------------------------------------------------------------------------------

    function test_languageCodes() {
        compare(TextInImages.languageCode("fr_FR"), "fra");
        compare(TextInImages.languageCode("fr_CA.UTF-8"), "fra");
        compare(TextInImages.languageCode("en_US"), "eng");
        compare(TextInImages.languageCode("de"), "deu");
        compare(TextInImages.languageCode("pt-BR"), "por");
        compare(TextInImages.languageCode("zh_TW"), "chi_tra");
        compare(TextInImages.languageCode("zh_Hant_HK"), "chi_tra");
        compare(TextInImages.languageCode("zh_CN"), "chi_sim");
        compare(TextInImages.languageCode("C"), "");
        compare(TextInImages.languageCode(""), "");
    }

    function test_installedLanguages() {
        const out = "List of available languages in \"/usr/share/tessdata/\" (5):\neng\nfra\nosd\nscript/Latin\n../evil\n";
        compare(TextInImages.parseLanguages(out), ["eng", "fra", "osd"]);
        compare(TextInImages.chooseLanguages(["eng", "fra", "osd"], "fr_FR"), "fra+eng", "the session's language first, then English");
        compare(TextInImages.chooseLanguages(["eng", "osd"], "fr_FR"), "eng", "French not installed: English alone");
        compare(TextInImages.chooseLanguages(["fra"], "en_US"), "", "neither the language nor English");
        compare(TextInImages.chooseLanguages(["eng", "deu"], "en_GB"), "eng", "English once");
        compare(TextInImages.chooseLanguages([], "fr_FR"), "");
        compare(TextInImages.parseLanguages(""), []);
    }

    function test_tsvGivesWordsInReadingOrder() {
        const page = TextInImages.parseTsv(test.tsv);
        compare(page.width, 400);
        compare(page.height, 200);
        compare(page.words.map(w => w.text), ["Hello", "world", "again", "Total", "42"], "noise and malformed rows left out");
        compare(page.lines.length, 3);
        compare(page.lines[0].first, 0);
        compare(page.lines[0].last, 1);
        compare([page.lines[0].x, page.lines[0].y, page.lines[0].w, page.lines[0].h], [20, 20, 130, 20], "the union of its kept words");
        compare(page.lines[0].paragraph, page.lines[1].paragraph, "two lines of one paragraph");
        verify(page.lines[1].paragraph !== page.lines[2].paragraph);
        compare(page.words[2].line, 1);
        const empty = TextInImages.parseTsv("");
        compare(empty.words.length, 0);
        compare(empty.width, 0);
        compare(TextInImages.parseTsv("garbage\nmore garbage").words.length, 0);
        // A word outside the page it claims is dropped.
        compare(TextInImages.parseTsv("1\t1\t0\t0\t0\t0\t0\t0\t100\t100\t-1\t\n5\t1\t1\t1\t1\t1\t90\t10\t50\t20\t90\twide").words.length, 0);
    }

    function test_hitTestingAndSelection() {
        const page = TextInImages.parseTsv(test.tsv);
        compare(TextInImages.wordAt(page, 30, 30), 0, "on Hello");
        compare(TextInImages.wordAt(page, 85, 30), 0, "between Hello and world: the nearer word");
        compare(TextInImages.wordAt(page, 100, 18), 1, "just above the line: still on it");
        compare(TextInImages.wordAt(page, 300, 100), -1, "on no text: the press pans");
        compare(TextInImages.lineAt(page, 30, 60), 1);
        compare(TextInImages.wordNear(page, 390, 25), 1, "right of the first line: its last word");
        compare(TextInImages.wordNear(page, 0, 199), 3, "below everything: the nearest line's word");
        compare(TextInImages.selectionText(page, 0, 0), "Hello");
        compare(TextInImages.selectionText(page, 1, 3), "world\nagain\nTotal", "lines and paragraphs end with a line break");
        compare(TextInImages.selectionText(page, 4, 0), "Hello world\nagain\nTotal 42", "a drag upwards selects the same words");
        compare(TextInImages.selectionText(page, -1, 2), "");
        compare(TextInImages.selectionText(page, 0, 9), "");
        const boxes = TextInImages.selectionBoxes(page, 1, 3);
        compare(boxes.length, 3, "one box per line");
        compare([boxes[0].x, boxes[0].w], [90, 60], "the first line from the anchor word");
        compare([boxes[1].x, boxes[1].y, boxes[1].h], [20, 50, 20]);
        compare([boxes[2].x, boxes[2].w], [20, 50], "the last line up to the focus word");
        compare(TextInImages.range(page, 2, 1).from, 1);
        compare(TextInImages.range(page, 5, 1), null);
    }

    function test_onlyCleanWebLinksAreLinks() {
        verify(TextInImages.isLink("https://example.org/menu?table=4"));
        verify(TextInImages.isLink("HTTP://EXAMPLE.ORG/A"));
        verify(TextInImages.isLink("https://example.org:8443"));
        verify(!TextInImages.isLink("https://bank.example@other.example/"), "user information shows one host and opens another");
        verify(!TextInImages.isLink("javascript:alert(1)"));
        verify(!TextInImages.isLink("file:///etc/passwd"));
        verify(!TextInImages.isLink("otpauth://totp/a?secret=JBSWY3DP"));
        verify(!TextInImages.isLink("https://"));
        verify(!TextInImages.isLink("https://example.org/a b"));
        verify(!TextInImages.isLink("https://example.org/‮gpj.exe"), "a bidirectional override");
        verify(!TextInImages.isLink("https://example.org/\u0007"));
        verify(!TextInImages.isLink("https://example.org/" + "a".repeat(TextInImages.maxLinkLength)));
        compare(TextInImages.linkHost("https://Example.ORG:8443/a?b"), "example.org");
        compare(TextInImages.linkHost("WIFI:S:home;T:WPA;P:secret;;"), "");
    }

    function test_qrCodes() {
        const codes = TextInImages.parseCodes(0, "QR-Code:https://example.org/a\nQR-Code:BEGIN:VCARD\nFN:A\nEND:VCARD\nQR-Code:https://example.org/a\n");
        compare(codes.length, 2, "a code found twice is one chip");
        compare(codes[0].text, "https://example.org/a");
        verify(codes[0].link);
        compare(codes[0].host, "example.org");
        compare(codes[1].text, "BEGIN:VCARD\nFN:A\nEND:VCARD", "a code's own line breaks are kept");
        verify(!codes[1].link);
        compare(TextInImages.parseCodes(4, ""), [], "zbarimg's 4: no code");
        compare(TextInImages.parseCodes(-1, "QR-Code:x"), [], "a failed run gives nothing");
        compare(TextInImages.parseCodes(0, "QR-Code:1\nQR-Code:2\nQR-Code:3\nQR-Code:4\nQR-Code:5\n").length, TextInImages.maxCodes);
        compare(TextInImages.parseCodes(0, "garbage\n"), []);
    }

    // ---- the reading of one image at a time (ImageText.qml) -----------------------------------------------------------

    QtObject {
        id: tools
        // Whether the tools are installed: recognize answers 0 for a missing one.
        property bool tesseract: true
        property bool zbarimg: true
        property var calls: []
        property var cancelled: []
        property int last: 0
        signal recognized(int request, string tool, int exitCode, string output)
        function recognize(tool: string, index: int, languages: string): int {
            if ((tool === "qr" && !tools.zbarimg) || (tool !== "qr" && !tools.tesseract))
                return 0;
            tools.last++;
            tools.calls = tools.calls.concat([{id: tools.last, tool: tool, index: index, languages: languages}]);
            return tools.last;
        }
        function cancelRecognition(request: int): void {
            tools.cancelled = tools.cancelled.concat([request]);
        }
        function call(tool: string): var {
            for (let i = tools.calls.length - 1; i >= 0; i--) {
                if (tools.calls[i].tool === tool)
                    return tools.calls[i];
            }
            return null;
        }
    }

    ImageText {
        id: reader
        backend: tools
        fileIndex: 3
        url: ""
        active: true
    }

    function init() {
        reader.url = "";
        reader.active = true;
        // Each test starts from a window that has not asked for the languages yet.
        reader.languagesState = 0;
        reader.languages = "";
        reader.languagesRequest = 0;
        tools.tesseract = true;
        tools.zbarimg = true;
        tools.calls = [];
        tools.cancelled = [];
        // The view at fit, unturned, with a fresh reading (no selection) and no code.
        view.fit();
        view.turns = 0;
        view.textPage = TextInImages.parseTsv(test.tsv);
        view.codes = [];
    }

    function test_readsOneImageOnceAndCancelsOnChange() {
        reader.url = "file:///x/shot.png";
        compare(tools.calls.length, 0, "nothing before the viewer rests on the image");
        tryVerify(() => tools.call("qr") !== null);
        const qr = tools.call("qr");
        compare(qr.index, 3);
        const languages = tools.call("languages");
        verify(languages !== null, "the window asks tesseract for its languages once");
        compare(tools.call("text"), null, "the text waits for them");
        tools.recognized(languages.id, "languages", 0, "List of available languages in \"/usr/share/tessdata/\" (1):\neng\n");
        compare(reader.languages, "eng", "only English installed: English, whatever the session's language");
        const text = tools.call("text");
        verify(text !== null, "the text is read once the languages are known");
        compare(text.languages, "eng");
        compare(text.index, 3);
        tools.recognized(text.id, "text", 0, test.tsv);
        compare(reader.page.words.length, 5);
        tools.recognized(qr.id, "qr", 0, "QR-Code:https://example.org\n");
        compare(reader.codes.length, 1);
        compare(reader.codes[0].host, "example.org");
        // An answer for nobody (cancelled, another window) changes nothing.
        tools.recognized(999, "text", 0, "");
        compare(reader.page.words.length, 5);
        // Another image: what was read goes; the languages are not asked again.
        const before = tools.calls.length;
        reader.url = "file:///x/other.png";
        compare(reader.page.words.length, 0);
        compare(reader.codes.length, 0);
        tryVerify(() => tools.calls.length === before + 2);
        compare(tools.calls[before].tool, "qr");
        compare(tools.calls[before + 1].tool, "text");
        // Leaving it while it is read cancels both runs.
        reader.url = "";
        verify(tools.cancelled.indexOf(tools.calls[before].id) >= 0);
        verify(tools.cancelled.indexOf(tools.calls[before + 1].id) >= 0);
        // Their late answers are ignored.
        tools.recognized(tools.calls[before + 1].id, "text", 0, test.tsv);
        compare(reader.page.words.length, 0);
    }

    function test_settingOffReadsNothing() {
        reader.active = false;
        reader.url = "file:///x/shot.png";
        wait(400);
        compare(tools.calls.length, 0);
        reader.active = true;
        tryVerify(() => tools.call("qr") !== null, 2000, "turning it on reads the image shown");
        reader.active = false;
        compare(reader.codes.length, 0);
        verify(tools.cancelled.length > 0, "turning it off cancels the run");
    }

    function test_missingToolsAreSilent() {
        tools.zbarimg = false;
        reader.url = "file:///x/shot.png";
        wait(400);
        compare(tools.call("qr"), null, "no QR run without zbarimg");
        compare(reader.codes.length, 0);
        tools.recognized(9999, "qr", 0, "QR-Code:x");
        compare(reader.codes.length, 0);
    }

    // ---- the image view (ImageView.qml) --------------------------------------------------------------------------------

    QtObject {
        id: viewBackend
        property var copied: []
        property var opened: []
        function copyText(text: string, concealed: bool): void {
            viewBackend.copied = viewBackend.copied.concat([{text: text, concealed: concealed}]);
        }
        function openLink(link: string): bool {
            viewBackend.opened = viewBackend.opened.concat([link]);
            return true;
        }
    }

    ImageView {
        id: view
        anchors.fill: parent
        info: ({ok: true, kind: "image", name: "shot.png", url: "", width: 400, height: 200, frames: 1, animated: false})
        backend: viewBackend
        textPage: TextInImages.parseTsv(test.tsv)
    }

    function textLayerOf() {
        return findChild(view, "textLayer");
    }

    function chipsColumn() {
        return findChild(view, "codeChips");
    }

    // The first item under `item` with a `text` of `text` (a Button's label).
    function itemWithText(item, text) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.text === text)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_theLayerLiesOnThePicture() {
        const l = textLayerOf();
        verify(l !== null);
        compare(view.viewScale, 1, "a 400 x 200 picture fits the 800 x 600 view at its size");
        compare(l.width, 400);
        compare(l.unit, 1);
        view.rotate(1);
        compare(l.rotation, 90, "the layer turns with the picture");
        view.rotate(-1);
        view.setZoom(2);
        compare(l.unit, 2, "and scales with it");
        view.fit();
    }

    function test_dragSelectsWordsAndCopies() {
        const l = textLayerOf();
        verify(view.canSelectAll);
        verify(!view.canCopy);
        mousePress(l, 30, 30);
        mouseMove(l, 45, 45, -1, Qt.LeftButton);
        mouseMove(l, 60, 60, -1, Qt.LeftButton);
        mouseRelease(l, 60, 60);
        verify(view.canCopy);
        compare(l.selectedText(), "Hello world\nagain");
        viewBackend.copied = [];
        view.copy();
        compare(viewBackend.copied.length, 1);
        compare(viewBackend.copied[0].text, "Hello world\nagain");
        verify(!viewBackend.copied[0].concealed, "text read in a picture is plain text");
        // A click on a word clears it (no caret in a picture), and so does a press on no text (which goes to the view).
        mouseClick(l, 30, 30);
        verify(!view.canCopy);
        mouseDoubleClickSequence(l, 100, 30);
        compare(l.selectedText(), "world");
        mouseClick(l, 300, 100);
        verify(!view.canCopy);
        view.selectAll();
        compare(l.selectedText(), "Hello world\nagain\nTotal 42");
        // A new reading drops the selection.
        view.textPage = TextInImages.parseTsv(test.tsv);
        verify(!view.canCopy);
    }

    function test_iBeamOverText() {
        const l = textLayerOf();
        mouseMove(l, 30, 30);
        verify(l.overText);
        const area = findChild(l, "textArea");
        compare(area.cursorShape, Qt.IBeamCursor);
        mouseMove(l, 300, 120);
        verify(!l.overText);
        compare(area.cursorShape, Qt.ArrowCursor);
    }

    function test_contextMenu() {
        const l = textLayerOf();
        mouseDoubleClickSequence(l, 30, 30);
        compare(l.selectedText(), "Hello", "a double click selects the word");
        mouseClick(l, 30, 30, Qt.RightButton);
        const menu = findChild(view, "textMenu");
        verify(menu !== null);
        tryVerify(() => menu.opened);
        compare(menu.items.map(i => i.text), ["Copy Text", "Select All Text"]);
        verify(menu.items[0].enabled, "a word is selected");
        menu.chosen("copy");
        compare(viewBackend.copied[viewBackend.copied.length - 1].text, "Hello");
        menu.chosen("selectAll");
        compare(l.selectedText(), "Hello world\nagain\nTotal 42");
        menu.close();
        tryVerify(() => !menu.opened);
    }

    function test_codeChips() {
        verify(!chipsColumn().visible, "no code, no chip");
        view.codes = TextInImages.parseCodes(0, "QR-Code:https://example.org/menu\nQR-Code:WIFI:S:home;T:WPA;P:secret;;\n");
        const column = chipsColumn();
        verify(column.visible);
        compare(column.children.length - 1, 2, "one chip per code (and the Repeater)");
        waitForItemPolished(column);
        compare(column.x + column.width, view.width - Tokens.spacingLg, "at the bottom right");
        compare(column.y + column.height, view.height - Tokens.spacingLg);
        compare(column.height, 2 * Tokens.toolbarCapsule + Tokens.spacingSm, "two capsules, one above the other");
        verify(itemWithText(column, "example.org") !== null, "a link names its host");
        verify(itemWithText(column, "secret") === null && itemWithText(column, "WIFI:S:home;T:WPA;P:secret;;") === null,
               "any other code is never shown");
        verify(itemWithText(column, "QR Code 2") !== null);
        mouseClick(itemWithText(column, "Open Link"));
        compare(viewBackend.opened, ["https://example.org/menu"]);
        viewBackend.copied = [];
        mouseClick(itemWithText(column, "Copy"));
        compare(viewBackend.copied.length, 1);
        compare(viewBackend.copied[0].text, "WIFI:S:home;T:WPA;P:secret;;");
        verify(viewBackend.copied[0].concealed, "kept out of the clipboard history");
        view.codes = [];
        verify(!chipsColumn().visible);
    }
}
