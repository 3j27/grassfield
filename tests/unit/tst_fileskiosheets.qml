pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"
import "../../apps/files/qml/KioSheetsLogic.js" as KioSheetsLogic

// KIO's questions in Files as sheets (apps/files/qml/KioSheets.qml, KioSheetsLogic.js; ADR-0035 D-12 a,
// docs/specs/system-dialogs.md section 9): the macOS texts and buttons for each kind, and the replies the sheet sends
// (FilesApp.prompts.reply) for the buttons, Return, Esc, "Apply to All", "Show Certificate" and "Always trust"; a question
// withdrawn while shown; a kind this version doesn't know. The C++ side, with real KIO jobs, is
// tests/unit/files/tst_kiodialogs.cpp; the window that shows a question, tests/unit/tst_filesbrowser.qml.
TestCase {
    id: test
    name: "FilesKioSheets"
    when: windowShown
    width: 640
    height: 480
    visible: true

    // FilesApp.prompts: the question on screen, the ones waiting behind it (shown at once after a reply, as KioPrompts does),
    // and the replies the sheet sent.
    QtObject {
        id: fakePrompts
        property var current: ({})
        property var waiting: []
        property var replies: []
        function reply(id: int, answer: var): void {
            fakePrompts.replies = fakePrompts.replies.concat([{
                    id: id,
                    button: answer.button,
                    applyToAll: answer.applyToAll,
                    alwaysTrust: answer.alwaysTrust
                }]);
            const next = fakePrompts.waiting.length > 0 ? fakePrompts.waiting[0] : ({});
            fakePrompts.waiting = fakePrompts.waiting.slice(1);
            fakePrompts.current = next;
        }
    }

    Component {
        id: sheetsComponent
        Item {
            property alias sheets: sheets
            width: test.width
            height: test.height
            KioSheets {
                id: sheets
                prompts: fakePrompts
                shown: true
            }
        }
    }

    function init(): void {
        fakePrompts.current = ({});
        fakePrompts.waiting = [];
        fakePrompts.replies = [];
    }

    function make(): var {
        const host = createTemporaryObject(sheetsComponent, test);
        verify(host !== null, "KioSheets.qml");
        return host.sheets;
    }

    // The visible item under `root` whose `text` is `text` (a button, a check box), or null.
    function find(root: var, text: string): var {
        const walk = item => {
            if (!item || !item.visible)
                return null;
            if (item.text === text && (item.clicked !== undefined || item.toggled !== undefined))
                return item;
            for (let i = 0; i < item.children.length; i++) {
                const found = walk(item.children[i]);
                if (found)
                    return found;
            }
            return null;
        };
        return walk(root);
    }

    // Clicks the visible control `text` of `sheet` once the sheet has laid it out (a sheet just opened, or a part just shown,
    // is placed on the next polish).
    function click(sheet: var, text: string): void {
        verify(waitForPolish(sheet.Window.window, 1000), "the sheet is laid out");
        const item = test.find(sheet, text);
        verify(item !== null, text);
        mouseClick(item);
    }

    // The sheet is shown and takes input (KioSheets holds it for the double-click interval after a question changes).
    function shown(sheet: var): void {
        tryVerify(() => sheet.visible, 1000, "the sheet shows");
        tryVerify(() => !sheet.holdInput, 2000, "the sheet takes input");
    }

    function sheetOf(sheets: var): var {
        for (let i = 0; i < sheets.children.length; i++) {
            if (sheets.children[i] instanceof Sheet)
                return sheets.children[i];
        }
        return null;
    }

    function conflict(extra: var): var {
        return Object.assign({
            id: 7,
            kind: "conflict",
            name: "Report.pdf",
            folder: "Documents",
            mode: "copy",
            merge: false,
            replace: true,
            keepBoth: true,
            skip: false,
            applyToAll: false
        }, extra);
    }

    // --- texts and buttons (KioSheetsLogic.js) ---------------------------------------------------------------------------

    function test_conflictTexts(): void {
        let s = KioSheetsLogic.sheet(test.conflict({}));
        compare(s.title, "An item named “Report.pdf” already exists in this location.");
        compare(s.message, "Do you want to replace it with the one you’re copying?");
        compare(s.confirmText, "Replace");
        compare(s.cancelText, "Stop");
        compare(s.extras.map(e => e.id), ["keepBoth"]);
        compare(s.applyToAll, false);

        // Finder names the older or newer item.
        s = KioSheetsLogic.sheet(test.conflict({
            mode: "move",
            srcModified: new Date(2026, 9, 2),
            destModified: new Date(2026, 9, 1)
        }));
        compare(s.title, "An older item named “Report.pdf” already exists in this location.");
        compare(s.message, "Do you want to replace it with the newer one you’re moving?");
        s = KioSheetsLogic.sheet(test.conflict({
            srcModified: new Date(2026, 9, 1),
            destModified: new Date(2026, 9, 2)
        }));
        compare(s.title, "A newer item named “Report.pdf” already exists in this location.");
        compare(s.message, "Do you want to replace it with the older one you’re copying?");

        // Several items: Skip and Apply to All; a folder onto a folder merges.
        s = KioSheetsLogic.sheet(test.conflict({
            skip: true,
            applyToAll: true,
            merge: true,
            name: "Photos"
        }));
        compare(s.title, "A folder named “Photos” already exists in this location.");
        compare(s.confirmText, "Merge");
        compare(s.extras.map(e => e.id), ["keepBoth", "skip"]);
        compare(s.applyToAll, true);

        // No Replace (the item itself): Keep Both is the default.
        s = KioSheetsLogic.sheet(test.conflict({
            replace: false
        }));
        compare(s.confirmId, "keepBoth");
        compare(s.extras, []);
    }

    function test_otherKinds(): void {
        let s = KioSheetsLogic.sheet({
            id: 1,
            kind: "skip",
            text: "Access denied",
            retry: true,
            rename: false,
            skip: true,
            applyToAll: true
        });
        compare(s.title, "The operation can’t be completed.");
        compare(s.message, "Access denied");
        compare([s.confirmId, s.cancelId], ["retry", "stop"]);
        compare(s.extras.map(e => e.id), ["skip"]);
        // One item: no Skip (KIO's SkipDialog); one that can't be retried has OK only, which stops.
        s = KioSheetsLogic.sheet({
            id: 11,
            kind: "skip",
            text: "Access denied",
            retry: true,
            rename: false,
            skip: false,
            applyToAll: false
        });
        compare(s.extras, []);
        s = KioSheetsLogic.sheet({
            id: 12,
            kind: "skip",
            text: "Access denied",
            retry: false,
            rename: false,
            skip: false,
            applyToAll: false
        });
        compare([s.confirmText, s.confirmId, s.showCancel], ["OK", "stop", false]);

        s = KioSheetsLogic.sheet({
            id: 2,
            kind: "delete",
            type: "emptyTrash",
            count: 3,
            name: "a"
        });
        compare(s.title, "Are you sure you want to permanently erase the items in the Trash?");
        compare(s.confirmText, "Empty Trash");
        verify(s.destructive);
        s = KioSheetsLogic.sheet({
            id: 3,
            kind: "delete",
            type: "delete",
            count: 1,
            name: "a.txt"
        });
        compare(s.title, "Are you sure you want to delete “a.txt”?");
        compare(s.message, "You can’t undo this action.");

        // A two-action question without Cancel: Esc gives the secondary action (KMessageBox).
        s = KioSheetsLogic.sheet({
            id: 4,
            kind: "message",
            title: "",
            text: "Overwrite?",
            details: "",
            primary: "Yes",
            secondary: "No",
            cancel: false,
            okOnly: false,
            warning: false
        });
        compare([s.title, s.message, s.confirmText, s.cancelText, s.cancelId], ["Overwrite?", "", "Yes", "No", "secondary"]);
        s = KioSheetsLogic.sheet({
            id: 5,
            kind: "message",
            title: "Server",
            text: "Save it?",
            details: "more",
            primary: "Save",
            secondary: "Discard",
            cancel: true,
            okOnly: false,
            warning: true
        });
        compare(s.extras.map(e => e.id), ["secondary", "details"]);
        compare(s.cancelId, "cancel");
        verify(s.destructive);
        s = KioSheetsLogic.sheet({
            id: 6,
            kind: "message",
            title: "",
            text: "Done",
            details: "",
            primary: "",
            secondary: "",
            cancel: false,
            okOnly: true,
            warning: false
        });
        compare([s.confirmText, s.confirmId, s.showCancel], ["OK", "ok", false]);

        s = KioSheetsLogic.sheet({
            id: 8,
            kind: "certificate",
            host: "files.example.org",
            error: "expired",
            chain: []
        });
        compare(s.title, "Files can’t verify the identity of the server “files.example.org”.");
        verify(s.returnCancels, "Cancel is the default");
        compare(s.extras.map(e => e.id), ["certificate"]);

        compare(KioSheetsLogic.sheet({}), null);
        compare(KioSheetsLogic.sheet({
            id: 9,
            kind: "future"
        }), null);
    }

    function test_chainLines(): void {
        const lines = KioSheetsLogic.chainLines([{
                readable: true,
                subject: "files.example.org",
                issuer: "Example CA",
                validFrom: "a",
                validUntil: "b",
                sha256: "AB:CD",
                problems: ["The certificate has expired"]
            }, {
                readable: false,
                problems: []
            }], d => "<" + d + ">");
        compare(lines, ["files.example.org", "Issued by: Example CA", "Valid from <a> to <b>", "SHA-256: AB:CD", "• The certificate has expired", "", "A certificate that can’t be read"]);
    }

    // --- the sheet (KioSheets.qml) ----------------------------------------------------------------------------------

    function test_conflictReplies(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        verify(sheet !== null);
        verify(!sheet.visible, "no question, no sheet");

        fakePrompts.current = test.conflict({
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        compare(sheet.title, "An item named “Report.pdf” already exists in this location.");
        test.click(sheet, "Keep Both");
        compare(fakePrompts.replies.length, 1);
        compare(fakePrompts.replies[0].id, 7);
        compare(fakePrompts.replies[0].button, "keepBoth");
        compare(fakePrompts.replies[0].applyToAll, false);
        verify(!sheet.visible);

        // Apply to All, then Return: Replace for all.
        fakePrompts.current = test.conflict({
            id: 8,
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        test.click(sheet, "Apply to All");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "replace");
        compare(fakePrompts.replies[1].applyToAll, true);

        // A new question starts with Apply to All off; Esc stops.
        fakePrompts.current = test.conflict({
            id: 9,
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        verify(!test.find(sheet, "Apply to All").checked, "Apply to All starts off");
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[2].button, "stop");
        compare(fakePrompts.replies[2].applyToAll, false);

        // Skip.
        fakePrompts.current = test.conflict({
            id: 10,
            skip: true
        });
        test.shown(sheet);
        test.click(sheet, "Skip");
        compare(fakePrompts.replies[3].button, "skip");
        compare(fakePrompts.replies.length, 4);
    }

    function test_resume(): void {
        const s = KioSheetsLogic.sheet(test.conflict({
            resume: true,
            keepBoth: false
        }));
        compare(s.title, "Part of “Report.pdf” is already in this location.");
        compare([s.confirmText, s.confirmId, s.cancelId], ["Resume", "resume", "stop"]);
        compare(s.extras, [{id: "replace", text: "Start Over"}]);

        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 41,
            resume: true,
            keepBoth: false
        });
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "resume");
    }

    // A question hidden a moment (another sheet or a menu of the window) comes back with the choices made on it.
    function test_choicesKeptWhileHidden(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 51,
            skip: true,
            applyToAll: true
        });
        test.shown(sheet);
        test.click(sheet, "Apply to All");
        sheets.shown = false;
        tryVerify(() => !sheet.visible, 1000);
        sheets.shown = true;
        test.shown(sheet);
        verify(test.find(sheet, "Apply to All").checked, "Apply to All kept");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].applyToAll, true);
    }

    // A deletion: Delete answers "delete"; Return cancels (a destructive button is never the default, common rule 3).
    function test_deletion(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const request = {
            id: 61,
            kind: "delete",
            type: "delete",
            count: 1,
            name: "a.txt"
        };
        fakePrompts.current = request;
        test.shown(sheet);
        test.click(sheet, "Delete");
        compare(fakePrompts.replies[0].button, "delete");
        fakePrompts.current = Object.assign({}, request, {
            id: 62
        });
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "cancel");
    }

    // A worker's warning: Return never takes its action. With a Cancel it cancels; without one it gives the secondary
    // action (KDE's own box defaults to Cancel; an sftp host key that changed must not be accepted by Return).
    function test_warningReturnIsSafe(): void {
        let s = KioSheetsLogic.sheet({
            id: 70,
            kind: "message",
            title: "",
            text: "The host key changed.",
            details: "",
            primary: "Connect Anyway",
            secondary: "",
            cancel: true,
            okOnly: false,
            warning: true
        });
        verify(s.returnCancels, "a warning with Cancel");
        s = KioSheetsLogic.sheet({
            id: 71,
            kind: "message",
            title: "",
            text: "Overwrite?",
            details: "",
            primary: "Yes",
            secondary: "No",
            cancel: false,
            okOnly: false,
            warning: false
        });
        verify(!s.returnCancels, "a question that is not a warning keeps its primary action as the default");

        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = {
            id: 72,
            kind: "message",
            title: "Host key",
            text: "The host key changed.",
            details: "",
            primary: "Connect Anyway",
            secondary: "",
            cancel: true,
            okOnly: false,
            warning: true
        };
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "cancel");
        fakePrompts.current = {
            id: 73,
            kind: "message",
            title: "",
            text: "Replace the remote file?",
            details: "",
            primary: "Replace",
            secondary: "Keep",
            cancel: false,
            okOnly: false,
            warning: true
        };
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "secondary");
    }

    // A request without the merge field is never a merge.
    function test_conflictWithoutMergeField(): void {
        const request = test.conflict({});
        delete request.merge;
        const s = KioSheetsLogic.sheet(request);
        compare(s.title, "An item named “Report.pdf” already exists in this location.");
        compare(s.confirmText, "Replace");
    }

    // Two jobs' conflicts, one after the other: a double click on Replace answers the first one only; the second shows and
    // takes no input for the double-click interval (Return held down does not answer it either), then answers as usual.
    function test_secondQuestionIsNotAnsweredUnseen(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.waiting = [test.conflict({
                id: 82,
                name: "Other.pdf"
            })];
        fakePrompts.current = test.conflict({
            id: 81
        });
        test.shown(sheet);
        verify(waitForPolish(sheet.Window.window, 1000));
        const replace = test.find(sheet, "Replace");
        verify(replace !== null);
        mouseDoubleClickSequence(replace);
        compare(fakePrompts.replies.length, 1, "the double click answered one question");
        compare(fakePrompts.replies[0].id, 81);
        tryVerify(() => sheet.visible, 1000);
        verify(sheet.holdInput, "the second question holds its input");
        compare(sheet.title, "An item named “Other.pdf” already exists in this location.");
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies.length, 1, "Return right after it changed does not answer it");
        wait(Qt.styleHints.mouseDoubleClickInterval + 50);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies.length, 2);
        compare(fakePrompts.replies[1].id, 82);
    }

    // Return is the default button's in every new question, also after the user tabbed to another button in the last one.
    function test_returnIsTheDefaultAfterTab(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({
            id: 101
        });
        test.shown(sheet);
        keyClick(Qt.Key_Tab);
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[0].button, "stop");
        fakePrompts.current = test.conflict({
            id: 102
        });
        test.shown(sheet);
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[1].button, "replace", "Return is Replace's, not the button tabbed to last time");
    }

    // A long worker message: the sheet stays within its window, the buttons on screen, the text scrolls.
    function test_longMessageKeepsTheButtonsOnScreen(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const lines = [];
        for (let i = 0; i < 200; i++)
            lines.push("Line " + i + " of what the server said.");
        fakePrompts.current = {
            id: 91,
            kind: "message",
            title: "Server",
            text: lines.join("\n"),
            details: "",
            primary: "",
            secondary: "",
            cancel: false,
            okOnly: true,
            warning: false
        };
        test.shown(sheet);
        verify(waitForPolish(sheet.Window.window, 1000));
        const ok = test.find(sheet, "OK");
        verify(ok !== null);
        const bottom = ok.mapToItem(sheets, 0, ok.height).y;
        verify(bottom <= sheets.height, "the OK button is inside the window (" + bottom + " <= " + sheets.height + ")");
        wait(Qt.styleHints.mouseDoubleClickInterval + 50);
        mouseClick(ok);
        compare(fakePrompts.replies[0].button, "ok");
    }

    function test_withdrawnQuestion(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({});
        test.shown(sheet);
        // The job ended: KioPrompts withdraws the question, unanswered.
        fakePrompts.current = ({});
        tryVerify(() => !sheet.visible, 1000, "the sheet goes with its question");
        compare(fakePrompts.replies, []);
    }

    function test_certificate(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        const request = {
            id: 21,
            kind: "certificate",
            host: "files.example.org",
            error: "The certificate has expired",
            chain: [{
                    readable: true,
                    subject: "files.example.org",
                    issuer: "Example CA",
                    validFrom: new Date(2025, 0, 1),
                    validUntil: new Date(2026, 0, 1),
                    sha256: "AB:CD",
                    problems: ["The certificate has expired"]
                }]
        };
        fakePrompts.current = request;
        test.shown(sheet);
        // Return cancels: connecting is never the default.
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "cancel");

        fakePrompts.current = Object.assign({}, request, {
            id: 22
        });
        test.shown(sheet);
        verify(test.find(sheet, "Always trust “files.example.org”") === null, "Always trust comes with the certificate");
        test.click(sheet, "Show Certificate");
        verify(sheet.visible, "Show Certificate keeps the sheet");
        verify(test.find(sheet, "Hide Certificate") !== null);
        test.click(sheet, "Always trust “files.example.org”");
        test.click(sheet, "Continue");
        compare(fakePrompts.replies[1].button, "continue");
        compare(fakePrompts.replies[1].alwaysTrust, true);

        // The next certificate starts untrusted, its details hidden.
        fakePrompts.current = Object.assign({}, request, {
            id: 23
        });
        test.shown(sheet);
        verify(test.find(sheet, "Show Certificate") !== null);
        test.click(sheet, "Continue");
        compare(fakePrompts.replies[2].alwaysTrust, false);
    }

    function test_unknownKindStops(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = {
            id: 31,
            kind: "future"
        };
        tryVerify(() => fakePrompts.replies.length === 1, 1000);
        compare(fakePrompts.replies[0].button, "stop");
        verify(!sheet.visible);
    }

    function test_notShownHere(): void {
        const host = createTemporaryObject(sheetsComponent, test);
        host.sheets.shown = false;
        const sheet = test.sheetOf(host.sheets);
        fakePrompts.current = test.conflict({});
        wait(50);
        verify(!sheet.visible, "another window shows it");
        host.sheets.shown = true;
        tryVerify(() => sheet.visible, 1000, "this window, once it is the one");
        compare(fakePrompts.replies, []);
    }
}
