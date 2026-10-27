pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform
import qs.search
import qs.services
import "services/ClipboardLogic.js" as Logic

// Search's Clipboard view on the REAL Search controller and the REAL Clipboard service (ADR-0034 step 2; scripts/dev/test.sh:
// `qs -p tests/shell/search_clipboard`, offscreen, a dev session; prints "search-clipboard: PASS" or the failures). No helper
// runs: the dev session has no GRASSFIELD_CLIPBOARD_DISPLAY (state "dev-off"), so the helper's lines are handed to
// Clipboard.handle() as the helper would print them, and nothing touches a real clipboard or compositor.
// - entering and leaving the view (⌘4 / the button, Backspace, Super+Ctrl+V's toggle), the first-use prompt, Not Now, Allow;
// - the rows (pinned first), the helper's search answers (stale ones ignored), Copy (Search stays, the row says Copied),
//   Delete (the next row takes the selection), the pin-full notice, the preview that follows the selection;
// - the paste: copy only and Search closes with no target window; with a target, Search closes once the helper owns the item,
//   and the paste is dropped when the target closes; an "A" with nothing keeps Search open; the helper's lock closes Search.
ShellRoot {
    id: root

    property var failures: []
    property int step: 0
    property int waited: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function item(id: string, pinnedAt: int, copiedAt: int, title: string): string {
        return Logic.line(["I", id, "text", "text/plain;charset=utf-8", String(title.length), String(copiedAt), String(pinnedAt), "0", "0", title, title, "", "kitty"]);
    }

    function keys(): string {
        return search.rows.map(r => r.item.clip.id.slice(-1)).join("");
    }

    Search {
        id: search
    }

    // Before Allow: the prompt, Not Now, and Super+Ctrl+V's toggle.
    function first(): void {
        check("history off by default", !Clipboard.enabled);
        search.show("");
        check("Search opens on the results", search.open && search.view === "" && !search.clipboardView);
        search.setQuery("abc");
        search.enterClipboard();
        check("⌘4 enters the view with an empty field", search.clipboardView && search.query === "");
        check("the view asks first while the history is off", search.clipPrompt && search.rows.length === 0);
        search.clipNotNow();
        check("Not Now leaves the view, Search stays open", search.open && !search.clipboardView && !Clipboard.enabled);
        search.toggleClipboard();
        check("Super+Ctrl+V over open Search enters the view", search.open && search.clipboardView);
        search.toggleClipboard();
        check("Super+Ctrl+V in the view closes Search", !search.open && search.view === "");
        search.toggleClipboard();
        check("Super+Ctrl+V opens Search in the view", search.open && search.clipboardView);
        search.clipAllow();
    }

    // After Allow (Settings applied): rows, search, copy, delete, notices, preview.
    function second(): void {
        check("Allow turns the history on", Clipboard.enabled && !search.clipPrompt);
        check("no helper in a dev session without the display", Clipboard.state === "dev-off");
        const ids = ["00000000000000a1", "00000000000000a2", "00000000000000a3", "00000000000000a4"];
        Clipboard.handle(item(ids[0], 0, 1000, "alpha"));
        Clipboard.handle(item(ids[1], 0, 2000, "bravo"));
        Clipboard.handle(item(ids[2], 5000, 1500, "charlie"));
        Clipboard.handle(item(ids[3], 0, 3000, "delta"));
        check("rows: pinned first, then newest copy first (" + keys() + ")", keys() === "3421");
        check("a new item leaves the selection on its row", search.selectedClip().clip.id === ids[0]);
        search.leaveClipboard();
        search.enterClipboard();
        check("entering the view selects the first row", search.selected === 0 && search.selectedClip().clip.id === ids[2]);
        check("rows are clipboard rows", search.rows.every(r => r.item.kind === "clip" && r.item.key === "clip:" + r.item.clip.id));

        search.setQuery("br");
        const seq = search.clipSeq;
        Clipboard.handle(Logic.line(["R", String(seq - 1), ids[0]]));
        check("a stale search answer is ignored", keys() === "3421");
        Clipboard.handle(Logic.line(["R", String(seq), ids[1]]));
        check("the helper's answer filters the rows", keys() === "2");
        search.setQuery("zz");
        Clipboard.handle(Logic.line(["R", String(search.clipSeq)]));
        check("no match, no rows", search.rows.length === 0 && search.selected === -1);
        search.setQuery("");
        check("an empty query lists every item again", keys() === "3421");

        search.selected = 1;
        search.clipCopy(search.selectedClip());
        check("Copy keeps Search open and the row says Copied", search.open && search.clipCopiedKey === "clip:" + ids[3]);

        search.clipDelete(search.selectedClip());
        Clipboard.handle(Logic.line(["X", ids[3]]));
        check("Delete: the next row takes the selection (" + keys() + ", " + search.selected + ")", keys() === "321" && search.selected === 1);
        search.selected = 2;
        search.clipDelete(search.selectedClip());
        Clipboard.handle(Logic.line(["X", ids[0]]));
        check("Delete of the last row: the new last row", keys() === "32" && search.selected === 1);

        Clipboard.handle(Logic.line(["N", "pin-full", ids[1]]));
        check("pin-full shows the notice", search.clipNotice === "Pinned items are full");

        search.selected = 0;
        search.clipTogglePreview();
        check("Space previews the selected item", search.clipPreview !== null && search.clipPreview.id === ids[2]);
        Clipboard.handle(Logic.line(["V", ids[1], "", "late"]));
        check("another item's preview is ignored", search.clipPreviewText === "");
        Clipboard.handle(Logic.line(["V", ids[2], "", "charlie\nline 2"]));
        check("the preview shows the helper's text", search.clipPreviewReady && search.clipPreviewText === "charlie\nline 2");
        search.selected = 1;
        check("the preview follows the selection", search.clipPreview !== null && search.clipPreview.id === ids[1] && !search.clipPreviewReady);
        search.clipTogglePreview();
        check("Space again closes the preview", search.clipPreview === null);

        search.leaveClipboard();
        check("Backspace in the empty field leaves the view", search.open && !search.clipboardView && search.clipNotice === "");

        // The paste with no window to paste into (Search opened over the desktop): copied only, and Search closes.
        search.enterClipboard();
        Clipboard.watchTarget("");
        search.clipPaste(search.selectedClip(), false);
        check("no target: copied only, Search closes", !search.open && Clipboard.lastPaste === "copied only" && Clipboard.pendingPaste === null);

        // A target: Search stays until the helper owns the item, then closes; nothing is pasted once the target closed.
        search.toggleClipboard();
        Clipboard.watchTarget("0xABCDEF12");
        check("the target is kept as lower-case hex", Clipboard.pasteTarget === "abcdef12");
        search.clipPaste(search.selectedClip(), true);
        check("Search waits for the helper", search.open && Clipboard.pendingPaste !== null && Clipboard.pendingPaste.plain === false);
        Clipboard.handle(Logic.line(["A", ids[1]]));
        check("the helper owns another item: nothing yet", search.open && !Clipboard.pendingPaste.copied);
        Clipboard.handle(Logic.line(["A", ids[2]]));
        check("the helper owns the item: Search closes", !search.open && Clipboard.pendingPaste !== null && Clipboard.pendingPaste.copied);
        Compositor.windowClosed("abcdef12");
        check("the closed target is noted", Clipboard.pasteTargetClosed);
    }

    // A poll later: the paste was dropped; an "A" with nothing keeps Search open; the helper's lock closes Search.
    function third(): void {
        check("the paste is dropped when the target closed (" + Clipboard.lastPaste + ")", Clipboard.pendingPaste === null && Clipboard.lastPaste === "the window closed");

        search.toggleClipboard();
        Clipboard.watchTarget("abcdef13");
        search.clipPaste(search.selectedClip(), false);
        Clipboard.handle(Logic.line(["A", ""]));
        check("the helper could not copy: Search stays, nothing pasted", search.open && Clipboard.pendingPaste === null && Clipboard.lastPaste === "not copied");

        Clipboard.handle(Logic.line(["L", "1"]));
        check("the helper's lock closes Search", !search.open);
        search.toggleClipboard();
        check("locked by another program: Super+Ctrl+V opens nothing", !search.open && !search.clipboardView);
        Clipboard.handle(Logic.line(["L", "0"]));
        search.toggleClipboard();
        check("unlocked: the view opens again", search.open && search.clipboardView);
        search.hide();
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("search-clipboard: PASS");
            Qt.exit(0);
        } else {
            console.log("search-clipboard: FAIL " + failures.join(", "));
            Qt.exit(1);
        }
    }

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            root.waited += interval;
            if (root.step === 0 && root.waited >= 200) {
                root.first();
                root.step = 1;
                root.waited = 0;
            } else if (root.step === 1 && Clipboard.enabled) {
                root.second();
                root.step = 2;
                root.waited = 0;
            } else if (root.step === 1 && root.waited > 5000) {
                root.check("Allow applied the setting within 5 s", false);
                root.finish();
            } else if (root.step === 2 && root.waited >= 4 * Logic.PASTE_POLL_MS) {
                root.third();
                root.finish();
            }
        }
    }
}
