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

    // FilesApp.prompts: the question on screen, and the replies the sheet sent.
    QtObject {
        id: fakePrompts
        property var current: ({})
        property var replies: []
        function reply(id: int, answer: var): void {
            fakePrompts.replies = fakePrompts.replies.concat([{
                    id: id,
                    button: answer.button,
                    applyToAll: answer.applyToAll,
                    alwaysTrust: answer.alwaysTrust
                }]);
            fakePrompts.current = ({});
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
            applyToAll: true
        });
        compare(s.title, "The operation can’t be completed.");
        compare(s.message, "Access denied");
        compare([s.confirmId, s.cancelId], ["retry", "stop"]);
        compare(s.extras.map(e => e.id), ["skip"]);

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
        tryVerify(() => sheet.visible, 1000, "the question opens the sheet");
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
        tryVerify(() => sheet.visible, 1000);
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
        tryVerify(() => sheet.visible, 1000);
        verify(!test.find(sheet, "Apply to All").checked, "Apply to All starts off");
        keyClick(Qt.Key_Escape);
        compare(fakePrompts.replies[2].button, "stop");
        compare(fakePrompts.replies[2].applyToAll, false);

        // Skip.
        fakePrompts.current = test.conflict({
            id: 10,
            skip: true
        });
        tryVerify(() => sheet.visible, 1000);
        test.click(sheet, "Skip");
        compare(fakePrompts.replies[3].button, "skip");
        compare(fakePrompts.replies.length, 4);
    }

    function test_withdrawnQuestion(): void {
        const sheets = test.make();
        const sheet = test.sheetOf(sheets);
        fakePrompts.current = test.conflict({});
        tryVerify(() => sheet.visible, 1000);
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
        tryVerify(() => sheet.visible, 1000);
        // Return cancels: connecting is never the default.
        keyClick(Qt.Key_Return);
        compare(fakePrompts.replies[0].button, "cancel");

        fakePrompts.current = Object.assign({}, request, {
            id: 22
        });
        tryVerify(() => sheet.visible, 1000);
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
        tryVerify(() => sheet.visible, 1000);
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
