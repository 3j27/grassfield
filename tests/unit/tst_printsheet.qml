pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// grassfield-portal's print sheet (apps/files/qml/PrintSheet.qml; ADR-0035 D-7, steps 6a and 6b; docs/specs/system-dialogs.md
// section 7, PR1-PR4) on a stand-in for Print (apps/portal/src/print.h): looking for printers, the default one and its options,
// another printer, the pages typed, Print with Return and Cancel with Esc, no printer with Add Printer…, the PDF pull-down (Save
// as PDF through the Save panel and back, Open in Preview), what the application cannot do left out; step 6b: the Presets, the
// printer's own options in their sections, and a document sent first with its preview and pages.
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
        property var reshown: []
        property var presets: []
        property var rendered: []
        property int added: 0
        property bool refuse: false

        signal printersListed(int id, var printers, string current, bool ok)
        signal printerChosen(int id, string printer, var capabilities, var choices)
        signal pdfChosen(int id, string uri)
        signal pdfCancelled(int id)
        signal documentReady(int id, int pages)
        signal pageRendered(int id, int page, string source)
        signal dismissed(int id)
        signal closed(int id)

        function choosePreset(id: int, preset: string, choices: var): void {
            fakeHost.presets = fakeHost.presets.concat([{id: id, preset: preset, choices: choices}]);
        }
        function renderPage(id: int, page: int, width: int, height: int): void {
            fakeHost.rendered = fakeHost.rendered.concat([{id: id, page: page, width: width, height: height}]);
        }

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
        property var windows: ({})
        function present(id: int, window: var): void {
            fakeHost.windows[id] = window;
            window.visible = true;
        }
        function reshow(id: int): void {
            fakeHost.reshown = fakeHost.reshown.concat([id]);
            const window = fakeHost.windows[id];
            if (window)
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

    // A printer with options of its own (print::toQml(Capabilities).options): two in Media & Quality, one in Printer Options.
    readonly property var optionCaps: Object.assign({}, test.officeCaps, {
        options: [{name: "media-source", section: "quality", defaultValue: "auto", values: [{value: "auto", label: "Automatic"}, {value: "tray-1", label: "Tray 1"}]},
            {name: "print-quality", section: "quality", defaultValue: "4", values: [{value: "3", label: "3"}, {value: "4", label: "4"}, {value: "5", label: "5"}]},
            {name: "output-bin", section: "printer", defaultValue: "upper", values: [{value: "upper", label: "Upper Bin"}, {value: "lower", label: "Lower Bin"}]}]
    })

    function choices(fields: var): var {
        return Object.assign({printer: "", copies: 1, collate: true, pages: "all", ranges: "", media: test.a4, orientation: "portrait",
                                 scale: 100, duplex: "simplex", color: true, outputUri: "", preview: false, options: {}, preset: "default"}, fields || {});
    }

    function request(fields: var): var {
        return Object.assign({appId: "org.example.Writer", title: "Print", modal: true, parented: false, acceptLabel: "", hasCurrentPage: false,
                                 hasSelection: false, canSavePdf: true, outputBasename: "", choices: test.choices({}), document: false,
                                 hasLastUsed: false}, fields || {});
    }

    function open(fields: var): var {
        fakeHost.answers = [];
        fakeHost.chosen = [];
        fakeHost.saves = [];
        fakeHost.reshown = [];
        fakeHost.presets = [];
        fakeHost.rendered = [];
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

    // The printer's options being read: Print is dimmed and Return prints nothing (they would be missing from the job).
    function test_no_print_while_the_options_are_read(): void {
        const sheet = test.open({});
        fakeHost.printersListed(7, test.printers, "Office", true);
        verify(sheet.reading);
        verify(!test.button(sheet, "Print").enabled);
        sheet.requestActivate();
        tryVerify(() => sheet.active, 1000);
        keyClick(Qt.Key_Return);
        compare(fakeHost.answers.length, 0, "Return waits for the options");
        fakeHost.printerChosen(7, "Office", test.officeCaps, test.choices({printer: "Office"}));
        keyClick(Qt.Key_Return);
        compare(fakeHost.answers.length, 1);
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
        const pdf = test.control(sheet, "PDF");
        verify(pdf.visible && pdf.enabled, "the PDF pull-down still");
        printer.picked("__add");
        compare(fakeHost.added, 1);
        fakeHost.printersListed(7, [], "", false);
        compare(printer.model[0].text, "Printers Not Responding");
    }

    function test_save_as_pdf(): void {
        const sheet = test.open({outputBasename: "Quarterly Report"});
        test.ready(sheet);
        const pdf = test.control(sheet, "PDF");
        compare(pdf.displayText, "PDF", "macOS's pull-down: its label, whatever was picked");
        compare(pdf.model.map(m => m.text), ["Save as PDF…", "Open in Preview"]);
        pdf.picked("save");
        compare(fakeHost.saves.length, 1);
        compare(fakeHost.saves[0].name, "Quarterly Report");
        compare(fakeHost.saves[0].title, "Save as PDF");
        verify(!sheet.visible, "the Save panel takes its place");
        fakeHost.pdfCancelled(7);
        verify(sheet.visible, "Cancel there: the sheet comes back");
        compare(fakeHost.reshown, [7], "under the application's id (Print's reshow)");
        compare(fakeHost.answers.length, 0);
        // A file the backend refuses (the request ending meanwhile): the sheet comes back the same way.
        fakeHost.refuse = true;
        pdf.picked("save");
        fakeHost.pdfChosen(7, "file:///home/u/Quarterly%20Report.pdf");
        verify(sheet.visible && !sheet.answered, "refused: the sheet again");
        compare(fakeHost.reshown, [7, 7]);
        fakeHost.refuse = false;
        pdf.picked("save");
        fakeHost.pdfChosen(7, "file:///home/u/Quarterly%20Report.pdf");
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].response, 0);
        compare(fakeHost.answers[0].choices.outputUri, "file:///home/u/Quarterly%20Report.pdf");
        compare(fakeHost.answers[0].choices.printer, "");
        compare(fakeHost.answers[0].choices.copies, 2, "the sheet's choices with it");
        compare(fakeHost.answers[0].choices.preview, false);

        const untitled = test.open({});
        test.control(untitled, "PDF").picked("save");
        compare(fakeHost.saves[0].name, "Untitled");
    }

    // Open in Preview (the PDF pull-down's second item): the document goes to Preview, not to a printer.
    function test_open_in_preview(): void {
        const sheet = test.open({});
        test.ready(sheet);
        test.control(sheet, "PDF").picked("preview");
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].response, 0);
        compare(fakeHost.answers[0].choices.preview, true);
        compare(fakeHost.answers[0].choices.printer, "");
        compare(fakeHost.answers[0].choices.outputUri, "");
        verify(sheet.answered);
    }

    // Presets: Default Settings, and Last Used Settings once something was printed (chosen first then, as macOS opens on them);
    // Print applies a preset (it needs the printer's options) and answers with the choices.
    function test_presets(): void {
        const first = test.open({});
        test.ready(first);
        compare(test.control(first, "Presets").model.map(m => m.id), ["default"], "nothing printed yet");

        const sheet = test.open({hasLastUsed: true, choices: test.choices({preset: "last"})});
        fakeHost.printersListed(7, test.printers, "Office", true);
        fakeHost.printerChosen(7, "Office", test.officeCaps, test.choices({printer: "Office", preset: "last", duplex: "vertical"}));
        const presets = test.control(sheet, "Presets");
        compare(presets.model.map(m => m.text), ["Default Settings", "Last Used Settings"]);
        compare(presets.value, "last");
        presets.picked("default");
        compare(fakeHost.presets.length, 1);
        compare(fakeHost.presets[0].preset, "default");
        compare(fakeHost.presets[0].choices.preset, "default");
        fakeHost.printerChosen(7, "Office", test.officeCaps, test.choices({printer: "Office", preset: "default"}));
        compare(presets.value, "default");
        compare(test.control(sheet, "Two-Sided").value, "simplex", "the preset's choices shown");
        presets.picked("default");
        compare(fakeHost.presets.length, 1, "the preset shown already: nothing asked");
    }

    // The printer's own options: in their sections (closed at first), only the ones it reports, its values with their names (the
    // standard qualities named here), the choice going with the answer.
    function test_printer_options(): void {
        const sheet = test.open({});
        fakeHost.printersListed(7, test.printers, "Office", true);
        fakeHost.printerChosen(7, "Office", test.optionCaps, test.choices({printer: "Office", options: {"media-source": "auto", "print-quality": "4", "output-bin": "upper"}}));
        const quality = test.find(sheet.contentItem, it => it.Accessible.name === "Media & Quality" && it.activeFocusOnTab === true);
        const printerOptions = test.find(sheet.contentItem, it => it.Accessible.name === "Printer Options" && it.activeFocusOnTab === true);
        verify(quality !== null && printerOptions !== null, "both sections");
        compare(test.control(sheet, "Quality"), null, "closed at first");
        // Laid out (the sections came with the printer's options) before a click lands on them.
        verify(waitForRendering(sheet.contentItem, 2000));
        mouseClick(quality);
        const qualityBox = test.control(sheet, "Quality");
        verify(qualityBox !== null && qualityBox.visible);
        compare(qualityBox.model.map(m => m.text), ["Draft", "Normal", "Best"]);
        compare(qualityBox.value, "4", "the printer's default");
        compare(test.control(sheet, "Feed From").model.map(m => m.text), ["Automatic", "Tray 1"]);
        compare(test.control(sheet, "Output Bin"), null, "its section is closed");
        qualityBox.picked("5");
        compare(sheet.choices.options["print-quality"], "5");
        // The keyboard opens a section too.
        sheet.requestActivate();
        tryVerify(() => sheet.active, 1000);
        printerOptions.forceActiveFocus();
        keyClick(Qt.Key_Space);
        verify(test.control(sheet, "Output Bin") !== null);
        test.button(sheet, "Print").clicked();
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].choices.options["print-quality"], "5");
        compare(fakeHost.answers[0].choices.options["output-bin"], "upper");

        // A printer that reports none of its own: no section.
        const mono = test.open({});
        fakeHost.printersListed(7, test.printers, "Mono", true);
        fakeHost.printerChosen(7, "Mono", test.monoCaps, test.choices({printer: "Mono"}));
        compare(test.find(mono.contentItem, it => it.Accessible.name === "Media & Quality" && it.activeFocusOnTab === true), null);
    }

    // A document the application sent first: its preview on the left, its pages turned with the arrows and Page Down; no
    // Orientation or Scale (the document is laid out already); nothing printed before it is read.
    function test_a_document_sent_first(): void {
        const sheet = test.open({document: true, title: "Report"});
        compare(sheet.width, Tokens.filesPrintSheetWidth + Tokens.filesPrintPreviewWidth, "the preview column on the left");
        verify(!test.control(sheet, "Orientation").visible, "the document is laid out already");
        verify(!test.control(sheet, "Scale, in per cent").visible);
        verify(test.find(sheet.contentItem, it => it.text === "Preparing Preview…" && it.visible) !== null);
        test.ready(sheet);
        verify(!test.button(sheet, "Print").enabled, "not before the document is read");
        verify(!test.control(sheet, "PDF").enabled);
        fakeHost.documentReady(7, 3);
        verify(test.button(sheet, "Print").enabled);
        compare(fakeHost.rendered.length, 1);
        compare(fakeHost.rendered[0].page, 0);
        verify(fakeHost.rendered[0].width > 0 && fakeHost.rendered[0].height > 0, "drawn for the page area's pixels");
        verify(test.find(sheet.contentItem, it => it.text === "1 of 3" && it.visible) !== null);
        fakeHost.pageRendered(7, 0, "");
        verify(test.find(sheet.contentItem, it => it.text === "No Preview" && it.visible) !== null, "a page that cannot be drawn");
        const previous = test.control(sheet, "Previous Page");
        const next = test.control(sheet, "Next Page");
        verify(!previous.enabled);
        next.clicked();
        compare(fakeHost.rendered[fakeHost.rendered.length - 1].page, 1);
        fakeHost.pageRendered(7, 0, "image://printpreview/late");
        compare(sheet.pageSource, "", "a page no longer shown is not shown");
        sheet.requestActivate();
        tryVerify(() => sheet.active, 1000);
        keyClick(Qt.Key_PageDown);
        compare(sheet.page, 2);
        verify(!next.enabled, "the last page");
        keyClick(Qt.Key_PageUp);
        compare(sheet.page, 1);
        compare(test.control(sheet, "Pages").model.map(m => m.id), ["all", "ranges"]);
        keyClick(Qt.Key_Return);
        compare(fakeHost.answers.length, 1);
        compare(fakeHost.answers[0].choices.printer, "Office");
        compare(fakeHost.answers[0].choices.preview, false);
    }

    function test_what_the_application_cannot_do(): void {
        const sheet = test.open({canSavePdf: false, hasSelection: true, acceptLabel: "Print Now"});
        test.ready(sheet);
        verify(!test.control(sheet, "PDF").visible, "an application that makes no PDF");
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
