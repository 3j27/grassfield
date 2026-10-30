pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// grassfield-portal's print sheet (apps/files/qml/PrintSheet.qml; ADR-0035 D-7, step 6a; docs/specs/system-dialogs.md section 7,
// PR1-PR4) on a stand-in for Print (apps/portal/src/print.h): looking for printers, the default one and its options, another
// printer, the pages typed, Print with Return and Cancel with Esc, no printer with Add Printer…, Save as PDF through the Save
// panel and back, and what the application cannot do left out.
TestCase {
    id: test
    name: "PrintSheet"
    when: windowShown
    visible: true
    width: 400
    height: 300

    // Print as the sheet uses it: it records the calls and answers what the test makes it say.
    QtObject {
        id: fakeHost

        property var answers: []
        property var chosen: []
        property var saves: []
        property int added: 0
        property bool refuse: false

        signal printersListed(int id, var printers, string current, bool ok)
        signal printerChosen(int id, string printer, var capabilities, var choices)
        signal pdfChosen(int id, string uri)
        signal pdfCancelled(int id)
        signal closed(int id)

        function choosePrinter(id: int, printer: string, choices: var): void {
            fakeHost.chosen = fakeHost.chosen.concat([{id: id, printer: printer, choices: choices}]);
        }
        // Print::tidyRanges: "1-3, 5" for what reads, "" for what does not (a range that runs backwards, a page 0, text).
        function tidyRanges(text: string): string {
            const parts = String(text).split(",").map(p => p.trim());
            if (parts.length === 0 || parts.some(p => !/^[0-9]+(-[0-9]+)?$/.test(p)))
                return "";
            for (const p of parts) {
                const ends = p.split("-").map(Number);
                if (ends[0] < 1 || (ends.length > 1 && ends[1] < ends[0]))
                    return "";
            }
            return parts.join(", ");
        }
        function answer(id: int, response: int, choices: var): bool {
            if (fakeHost.refuse && response === 0)
                return false;
            fakeHost.answers = fakeHost.answers.concat([{id: id, response: response, choices: choices}]);
            return true;
        }
        function addPrinter(): void {
            fakeHost.added += 1;
        }
        function savePdf(id: int, name: string, title: string): void {
            fakeHost.saves = fakeHost.saves.concat([{id: id, name: name, title: title}]);
        }
        function present(id: int, window: var): void {
            window.visible = true;
        }
        function fail(id: int): void {
        }
    }

    QtObject {
        id: fakeManager
        property string testAnswer: ""
    }

    Component {
        id: sheetComponent
        PrintSheet {}
    }

    readonly property var a4: ({name: "iso_a4_210x297mm", displayName: "A4", widthMm: 210, heightMm: 297, topMm: 3, bottomMm: 3, leftMm: 3, rightMm: 3})
    readonly property var a5: ({name: "iso_a5_148x210mm", displayName: "A5", widthMm: 148, heightMm: 210, topMm: 3, bottomMm: 3, leftMm: 3, rightMm: 3})
    readonly property var officeCaps: ({known: true, media: [test.a4, test.a5], defaultMedia: "iso_a4_210x297mm", twoSided: true, color: true, maxCopies: 50})
    readonly property var monoCaps: ({known: true, media: [test.a4], defaultMedia: "iso_a4_210x297mm", twoSided: false, color: false, maxCopies: 9})
    readonly property var printers: [{name: "Office", displayName: "Office Printer", location: "Hall", isDefault: true},
        {name: "Mono", displayName: "Mono Laser", location: "", isDefault: false}]

    function choices(fields: var): var {
        return Object.assign({printer: "", copies: 1, collate: true, pages: "all", ranges: "", media: test.a4, orientation: "portrait",
                                 scale: 100, duplex: "simplex", color: true, outputUri: ""}, fields || {});
    }

    function request(fields: var): var {
        return Object.assign({appId: "org.example.Writer", title: "Print", modal: true, parented: false, acceptLabel: "", hasCurrentPage: false,
                                 hasSelection: false, canSavePdf: true, outputBasename: "", choices: test.choices({})}, fields || {});
    }

    function open(fields: var): var {
        fakeHost.answers = [];
        fakeHost.chosen = [];
        fakeHost.saves = [];
        fakeHost.added = 0;
        fakeHost.refuse = false;
        // No window under it, as FilePanels.qml makes it (a Window made under an Item would be that item's window's child).
        const sheet = createTemporaryObject(sheetComponent, test, {host: fakeHost, manager: fakeManager, requestId: 7, request: test.request(fields),
                                                transientParent: null});
        verify(sheet !== null, "the sheet");
        fakeHost.present(7, sheet);
        tryVerify(() => sheet.visible, 1000);
        verify(waitForRendering(sheet.contentItem, 2000));
        return sheet;
    }

    // Office listed and chosen, its options read.
    function ready(sheet: var): void {
        fakeHost.printersListed(7, test.printers, "Office", true);
        compare(sheet.printer, "Office");
        verify(sheet.reading, "its options are being read");
        fakeHost.printerChosen(7, "Office", test.officeCaps, test.choices({printer: "Office", copies: 2}));
        verify(!sheet.reading);
    }

    function find(item: var, check: var): var {
        const stack = [item];
        while (stack.length) {
            const it = stack.pop();
            if (check(it))
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function control(sheet: var, name: string): var {
        return test.find(sheet.contentItem, it => it.accessibleName === name);
    }

    function button(sheet: var, text: string): var {
        return test.find(sheet.contentItem, it => it.text === text && it.primary !== undefined);
    }

    function test_looking_then_the_default_printer(): void {
        const sheet = test.open({});
        const printer = test.control(sheet, "Printer");
        verify(printer !== null);
        compare(printer.model[0].text, "Looking for printers…");
        compare(printer.model[printer.model.length - 1].id, "__add", "Add Printer… last");
        const print = test.button(sheet, "Print");
        verify(print !== null);
        verify(!print.enabled, "nothing to print on yet");
        test.ready(sheet);
        compare(printer.value, "Office");
        compare(printer.model.map(m => m.text), ["Office Printer", "Mono Laser", "Add Printer…"]);
        verify(print.enabled);
        compare(test.control(sheet, "Copies").value, 2, "the choices carried to the printer");
        verify(test.control(sheet, "Two-Sided").visible, "Office prints on two sides");
        verify(test.control(sheet, "Colour").visible);
        compare(test.control(sheet, "Paper Size").model.map(m => m.text), ["A4", "A5"]);
    }

    function test_another_printer(): void {
        const sheet = test.open({});
        test.ready(sheet);
        test.control(sheet, "Copies").value = 4;
        test.control(sheet, "Copies").valueModified();
        test.control(sheet, "Printer").picked("Mono");
        compare(fakeHost.chosen.length, 1);
        compare(fakeHost.chosen[0].printer, "Mono");
        compare(fakeHost.chosen[0].choices.copies, 4, "the choices made so far go with it");
        verify(!test.button(sheet, "Print").enabled, "not while its options are read");
        // Office's late answer is not Mono's.
        fakeHost.printerChosen(7, "Office", test.officeCaps, test.choices({printer: "Office"}));
        verify(sheet.reading);
        fakeHost.printerChosen(7, "Mono", test.monoCaps, test.choices({printer: "Mono", copies: 4, color: false}));
        verify(!test.control(sheet, "Two-Sided").visible, "Mono has one side");
        verify(!test.control(sheet, "Colour").visible);
        compare(test.control(sheet, "Copies").to, 9);
        verify(test.button(sheet, "Print").enabled);
        test.control(sheet, "Printer").picked("__add");
        compare(fakeHost.added, 1, "Add Printer… opens Settings > Printers");
        compare(sheet.printer, "Mono", "and changes no printer");
    }

    function test_pages_typed(): void {
        const sheet = test.open({hasCurrentPage: true});
        test.ready(sheet);
        compare(test.control(sheet, "Pages").model.map(m => m.id), ["all", "current", "ranges"], "no selection to print");
        test.control(sheet, "Pages").picked("ranges");
        const field = test.control(sheet, "Pages to print, for example 1-3, 5");
        verify(field.visible);
        field.text = "3-1";
        field.textEdited();
        verify(!test.button(sheet, "Print").enabled, "pages that do not read");
        field.text = "5,1-3";
        field.textEdited();
        verify(test.button(sheet, "Print").enabled);
        sheet.requestActivate();
        tryVerify(() => sheet.active, 1000);
        keyClick(Qt.Key_Return);
        compare(fakeHost.answers.length, 1, "Return prints");
        compare(fakeHost.answers[0].response, 0);
        compare(fakeHost.answers[0].choices.printer, "Office");
        compare(fakeHost.answers[0].choices.ranges, "5, 1-3", "the pages as Print tidies them");
        compare(fakeHost.answers[0].choices.outputUri, "");
        keyClick(Qt.Key_Escape);
        compare(fakeHost.answers.length, 1, "answered once");
    }

    function test_escape_cancels_and_a_refused_answer_keeps_the_sheet(): void {
        const sheet = test.open({});
        test.ready(sheet);
        fakeHost.refuse = true;
        test.button(sheet, "Print").clicked();
        verify(!sheet.answered, "the sheet stays");
        fakeHost.refuse = false;
        sheet.requestActivate();
        tryVerify(() => sheet.active, 1000);
        keyClick(Qt.Key_Escape);
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].response, 1);
    }

    function test_no_printer(): void {
        const sheet = test.open({});
        fakeHost.printersListed(7, [], "", true);
        const printer = test.control(sheet, "Printer");
        compare(printer.model.map(m => m.text), ["No Printers Available", "Add Printer…"]);
        verify(!test.button(sheet, "Print").enabled);
        const pdf = test.button(sheet, "Save as PDF…");
        verify(pdf.visible && pdf.enabled, "Save as PDF still");
        printer.picked("__add");
        compare(fakeHost.added, 1);
        fakeHost.printersListed(7, [], "", false);
        compare(printer.model[0].text, "Printers Not Responding");
    }

    function test_save_as_pdf(): void {
        const sheet = test.open({outputBasename: "Quarterly Report"});
        test.ready(sheet);
        test.button(sheet, "Save as PDF…").clicked();
        compare(fakeHost.saves.length, 1);
        compare(fakeHost.saves[0].name, "Quarterly Report");
        compare(fakeHost.saves[0].title, "Save as PDF");
        verify(!sheet.visible, "the Save panel takes its place");
        fakeHost.pdfCancelled(7);
        verify(sheet.visible, "Cancel there: the sheet comes back");
        compare(fakeHost.answers.length, 0);
        test.button(sheet, "Save as PDF…").clicked();
        fakeHost.pdfChosen(7, "file:///home/u/Quarterly%20Report.pdf");
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].response, 0);
        compare(fakeHost.answers[0].choices.outputUri, "file:///home/u/Quarterly%20Report.pdf");
        compare(fakeHost.answers[0].choices.printer, "");
        compare(fakeHost.answers[0].choices.copies, 2, "the sheet's choices with it");

        const untitled = test.open({});
        test.button(untitled, "Save as PDF…").clicked();
        compare(fakeHost.saves[0].name, "Untitled");
    }

    function test_what_the_application_cannot_do(): void {
        const sheet = test.open({canSavePdf: false, hasSelection: true, acceptLabel: "Print Now"});
        test.ready(sheet);
        verify(!test.button(sheet, "Save as PDF…").visible, "an application that makes no PDF");
        compare(test.control(sheet, "Pages").model.map(m => m.id), ["all", "selection", "ranges"]);
        verify(test.button(sheet, "Print Now") !== null, "the application's own label");
    }

    // A sheet that gets the keyboard late (behind the lock, under another window) takes keys only after a click.
    function test_a_late_sheet_waits_for_a_click(): void {
        const sheet = test.open({});
        test.ready(sheet);
        // Another window has the keyboard; the sheet gets it long after it was shown.
        const elsewhere = createTemporaryQmlObject("import QtQuick; Window { width: 120; height: 80; visible: true; transientParent: null }", test);
        elsewhere.requestActivate();
        tryVerify(() => elsewhere.active && !sheet.active, 1000);
        sheet.shownAt = Date.now() - 2 * Tokens.filesPanelLateFocusMs;
        sheet.pressedAt = 0;
        sheet.everActive = false;
        sheet.requestActivate();
        tryVerify(() => sheet.everActive, 1000);
        verify(sheet.keysHeld, "held");
        keyClick(Qt.Key_Return);
        compare(fakeHost.answers.length, 0, "a Return meant for another window prints nothing");
        mousePress(sheet.contentItem, 10, 10);
        mouseRelease(sheet.contentItem, 10, 10);
        verify(!sheet.keysHeld);
        keyClick(Qt.Key_Return);
        compare(fakeHost.answers.length, 1);
    }
}
