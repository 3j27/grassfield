import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"
import "../../apps/files/qml/TagColors.js" as TagColors

// grassfield-files colour tags in QML: the palette helper (tokens, swatch models of a selection), the dots drawn on
// items (at most Tokens.filesTagDotsMax) and the swatch row of the item menu and Get Info (states, disabled reason,
// pointer and keyboard).
TestCase {
    id: test
    name: "FilesTags"
    width: 400
    height: 200
    // Shown, so that pointer events reach the swatches (a TestCase item starts hidden).
    visible: true
    when: windowShown

    Component {
        id: dotsComponent
        TagDots {}
    }

    Component {
        id: rowComponent
        SwatchRow {
            width: 300
        }
    }

    SignalSpy {
        id: chosenSpy
        signalName: "chosen"
    }

    function test_paletteComesFromTokensInKeyOrder() {
        const colors = TagColors.list(Tokens);
        compare(colors.length, 7);
        compare(colors[0], Tokens.filesTagRed);
        compare(colors[1], Tokens.filesTagOrange);
        compare(colors[2], Tokens.filesTagYellow);
        compare(colors[3], Tokens.filesTagGreen);
        compare(colors[4], Tokens.filesTagBlue);
        compare(colors[5], Tokens.filesTagPurple);
        compare(colors[6], Tokens.filesTagGray);
        compare(TagColors.at(Tokens, 4), Tokens.filesTagBlue);
        compare(TagColors.at(Tokens, -1), "");
        compare(TagColors.at(Tokens, 7), "");
    }

    function test_swatchModelOfASelection() {
        const names = ["Rouge", "Orange", "Jaune", "Vert", "Bleu", "Violet", "Gris"];
        const s = TagColors.swatches(Tokens, names, [2, 1, 0, 0, 0, 0, 0]);
        compare(s.length, 7);
        compare(s[0].id, "tag:0");
        compare(s[0].name, "Rouge");
        compare(s[0].state, 2);
        compare(s[1].state, 1);
        compare(s[6].id, "tag:6");
        compare(s[6].color, Tokens.filesTagGray);
        // No states (the selection can't be tagged): every swatch off.
        verify(TagColors.swatches(Tokens, names, []).every(x => x.state === 0));
    }

    function test_dotsShowAtMostTheMaximum() {
        const dots = createTemporaryObject(dotsComponent, test, {colors: [0, 4, 6, 1]});
        compare(dots.shown.length, Tokens.filesTagDotsMax);
        compare(dots.shown, [0, 4, 6]);
        verify(dots.visible);
        dots.colors = [];
        verify(!dots.visible);
        dots.colors = [3];
        verify(dots.visible);
        // The row lays out on the next polish.
        tryCompare(dots, "width", Tokens.filesTagDotSize);
    }

    function test_swatchRowStatesCaptionAndChoice() {
        const names = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"];
        const row = createTemporaryObject(rowComponent, test, {model: TagColors.swatches(Tokens, names, [0, 0, 2, 0, 0, 0, 0]), caption: "Tags"});
        chosenSpy.target = row;
        chosenSpy.clear();
        waitForRendering(row);
        compare(row.captionText, "Tags");
        // Pointer on the third swatch: its name in the caption, a click chooses it.
        const step = Tokens.menuSwatchSize + 2 * Tokens.menuSwatchRing + Tokens.menuSwatchGap;
        const x = Tokens.menuItemPadding + 2 * step + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2;
        const y = Tokens.spacingXs + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2;
        mouseMove(row, x - 1, y);
        mouseMove(row, x, y);
        compare(row.captionText, "Yellow");
        mouseClick(row, x, y);
        compare(chosenSpy.count, 1);
        compare(chosenSpy.signalArguments[0][0], 2);
        // Keyboard, when the row has the focus.
        row.forceActiveFocus();
        row.hoveredIndex = -1;
        row.currentIndex = 0;
        keyClick(Qt.Key_Left);
        compare(row.currentIndex, 6, "wraps to the last swatch");
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Right);
        compare(row.currentIndex, 1);
        keyClick(Qt.Key_Return);
        compare(chosenSpy.count, 2);
        compare(chosenSpy.signalArguments[1][0], 1);
    }

    function test_disabledSwatchRowShowsItsReasonAndChoosesNothing() {
        const row = createTemporaryObject(rowComponent, test, {model: TagColors.swatches(Tokens, ["Red"], []), caption: "This volume can’t store tags.", enabled: false});
        chosenSpy.target = row;
        chosenSpy.clear();
        waitForRendering(row);
        compare(row.captionText, "This volume can’t store tags.");
        const x = Tokens.menuItemPadding + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2;
        const y = Tokens.spacingXs + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2;
        mouseClick(row, x, y);
        row.forceActiveFocus();
        row.currentIndex = 0;
        keyClick(Qt.Key_Return);
        compare(chosenSpy.count, 0);
        compare(row.captionText, "This volume can’t store tags.");
    }
}
