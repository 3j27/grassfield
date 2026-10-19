pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// Customize Folder window (apps/files/qml/CustomizeFolderWindow.qml): the keyboard path (Tab order: colour swatches, hex
// field, symbol grid, symbol field, Reset, Cancel, Done; every stop shows a focus ring), the symbol field keeps one
// grapheme cluster so the preview is what Done saves; and the global menu item follows the selection.
TestCase {
    id: test
    name: "FilesCustomize"
    when: windowShown
    width: 300
    height: 200

    // The FilesApp API the window uses.
    QtObject {
        id: fakeApp
        property var colorTagNames: ({})
        property int folderStyleRevision: 0
        property var applied: null
        property var resets: []
        function folderStyleOf(url: url): var {
            return {color: "", glyph: ""};
        }
        function applyFolderStyle(urls: var, color: string, glyph: string): var {
            applied = {color: color, glyph: glyph};
            return {ok: true, fellBack: false};
        }
        function resetFolderStyle(urls: var): var {
            return {ok: true, fellBack: false};
        }
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
    }

    Component {
        id: windowComponent

        CustomizeFolderWindow {
            app: fakeApp
            urls: ["file:///sandbox/Music"]
            folderName: "Music"
        }
    }

    function find(parent, name) {
        for (let i = 0; i < parent.children.length; i++) {
            if (parent.children[i].objectName === name)
                return parent.children[i];
            const deeper = find(parent.children[i], name);
            if (deeper)
                return deeper;
        }
        return null;
    }

    // What Tab does (QQuickWindow): the next item of the focus chain takes the focus with the Tab reason.
    function tab(win) {
        const next = win.activeFocusItem.nextItemInFocusChain(true);
        verify(next, "a next item");
        next.forceActiveFocus(Qt.TabFocusReason);
    }

    function label(item) {
        if (item.objectName !== "")
            return item.objectName;
        return item.text !== undefined ? item.text : "?";
    }

    function test_tabChain() {
        const win = createTemporaryObject(windowComponent, test);
        verify(win);
        const swatches = find(win.contentItem, "swatches");
        swatches.forceActiveFocus(Qt.TabFocusReason);
        const seen = [];
        for (let i = 0; i < 7; i++) {
            // What the focus is on.
            let item = win.activeFocusItem;
            // The TextInputs and Buttons are the active focus item themselves; a FocusScope forwards to itself.
            seen.push(label(item));
            tab(win);
        }
        compare(seen[0], "swatches");
        compare(seen[1], "hexField");
        compare(seen[2], "glyphGrid");
        compare(seen[3], "glyphField");
        compare(seen[4], "Reset");
        compare(seen[5], "Cancel");
        compare(seen[6], "Done");
    }

    function test_symbolGridShowsItsFocusRingOnTab() {
        const win = createTemporaryObject(windowComponent, test);
        const grid = find(win.contentItem, "glyphGrid");
        compare(grid.current, -1);
        grid.forceActiveFocus(Qt.TabFocusReason);
        compare(grid.current, 0, "the first symbol is current as soon as the grid has the focus");
        // With a chosen symbol the ring starts on it.
        grid.focus = false;
        win.glyph = win.glyphChoices[5];
        grid.current = -1;
        find(win.contentItem, "hexField").forceActiveFocus();
        grid.forceActiveFocus(Qt.TabFocusReason);
        compare(grid.current, 5);
    }

    // With a custom colour (matching no swatch) the swatch row still shows where the focus is: the ring starts on the
    // first swatch; with a swatch chosen it starts there.
    function test_swatchRowShowsItsFocusRingWithACustomColour() {
        const win = createTemporaryObject(windowComponent, test);
        win.pickedColor = "#123456";
        win.requestActivate();
        tryVerify(() => win.activeFocusItem !== null, 3000, "the window has the focus");
        const swatches = find(win.contentItem, "swatches");
        compare(swatches.currentIndex, -1);
        find(win.contentItem, "hexField").forceActiveFocus();
        swatches.forceActiveFocus(Qt.TabFocusReason);
        compare(swatches.currentIndex, 0, "the focus has a place");
        compare(swatches.markedIndex, 0, "and a ring");
        // Arrow keys move it from there.
        keyClick(Qt.Key_Right);
        compare(swatches.currentIndex, 1);
        // A chosen swatch: the ring starts on it.
        find(win.contentItem, "hexField").forceActiveFocus();
        swatches.currentIndex = -1;
        win.pickedColor = "accent";
        swatches.forceActiveFocus(Qt.TabFocusReason);
        compare(swatches.currentIndex, 1);
    }

    function test_symbolFieldKeepsOneSymbol() {
        const win = createTemporaryObject(windowComponent, test);
        const field = find(win.contentItem, "glyphField");
        field.text = "Holiday photos";
        field.textEdited();
        compare(field.text, "H", "the field holds one symbol");
        compare(win.glyph, "H", "the preview shows what is saved");
        field.text = "\u{1F3B5}x";
        field.textEdited();
        compare(field.text, "\u{1F3B5}");
        compare(win.glyph, "\u{1F3B5}");
        field.text = "‮evil";
        field.textEdited();
        compare(win.glyph, "");
        compare(field.text, "");
        // What the preview shows is what Done hands to Files.
        field.text = "Holiday";
        field.textEdited();
        win.finish(false);
        compare(fakeApp.applied.glyph, "H");
    }
}
