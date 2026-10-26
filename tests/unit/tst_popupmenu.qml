import QtQuick
import QtTest
import Grassfield.Ui

// The PopupMenu component driven by real key events (navigation model is in tst_menunav).
TestCase {
    id: testCase
    name: "PopupMenu"
    width: 400
    height: 400
    // Shown, so that pointer events reach the menus (a TestCase item starts hidden).
    visible: true
    when: windowShown

    Component {
        id: menuComponent
        PopupMenu {
            model: [
                {id: "a", text: "Alpha", shortcut: "Ctrl+A"},
                {separator: true},
                {id: "b", text: "Beta", enabled: false},
                {id: "c", text: "Gamma"},
                {id: "d", text: "Delta", submenu: [{id: "d1", text: "Delta one"}, {id: "d2", text: "Delta two"}]}
            ]
        }
    }

    Component {
        id: swatchMenuComponent
        PopupMenu {
            model: [
                {id: "open", text: "Open"},
                {id: "tags", swatches: [{id: "tag:0", color: Tokens.filesTagRed, name: "Red", state: 2}, {id: "tag:1", color: Tokens.filesTagOrange, name: "Orange", state: 1},
                        {id: "tag:2", color: Tokens.filesTagYellow, name: "Yellow", state: 0}], accessibleName: "Tags"},
                {id: "notags", swatches: [{id: "tag:0", color: Tokens.filesTagRed, name: "Red", state: 0}], enabled: false, caption: "This volume can’t store tags."},
                {id: "copy", text: "Copy"}
            ]
        }
    }

    Component {
        id: itemComponent
        MenuItem {
            width: 300
        }
    }

    SignalSpy {
        id: activatedSpy
        signalName: "activated"
    }

    SignalSpy {
        id: closeSpy
        signalName: "closeRequested"
    }

    function makeMenu() {
        const m = createTemporaryObject(menuComponent, testCase);
        m.forceActiveFocus();
        activatedSpy.target = m;
        activatedSpy.clear();
        closeSpy.target = m;
        closeSpy.clear();
        return m;
    }

    Component {
        id: checkMenuComponent
        PopupMenu {
            model: [
                {id: "a", text: "Alpha"},
                {separator: true},
                {id: "b", text: "Beta", checked: true},
                {id: "c", text: "Gamma"},
                {separator: true},
                {id: "d", text: "Delta", iconName: "gear"}
            ]
        }
    }

    function test_sizing() {
        const m = makeMenu();
        verify(m.width >= Tokens.menuMinWidth);
        verify(m.height > 0);
    }

    // The Text drawing `text` (the MenuItem carries the same property but no font).
    function labelOf(root: Item, text: string): var {
        for (const child of root.children) {
            if (child.text === text && child.font !== undefined)
                return child;
            const found = labelOf(child, text);
            if (found)
                return found;
        }
        return null;
    }

    function textItem(root: Item, text: string): var {
        for (const child of root.children) {
            if (child.text === text)
                return child;
            const found = textItem(child, text);
            if (found)
                return found;
        }
        return null;
    }

    // Shortcuts form a right-aligned column whatever the label's length (docs/specs/ui.md), as on macOS.
    function test_shortcutsAlignRight() {
        const short = createTemporaryObject(itemComponent, testCase, {text: "Open", shortcut: "Ctrl+O"});
        const long = createTemporaryObject(itemComponent, testCase, {text: "Glance at “Report.pdf”", shortcut: "Space"});
        for (const row of [short, long]) {
            const hint = textItem(row, row.shortcut);
            verify(hint !== null);
            fuzzyCompare(hint.mapToItem(row, hint.width, 0).x, row.width - Tokens.menuItemPadding, 0.5);
        }
    }

    // macOS 27 menu layout (ADR-0024): the label sits menuItemPadding inside the row; a section that holds a checkable row
    // moves its labels after the check column; an icon moves only its own row; the highlight is concentric with the menu.
    Component {
        id: layoutMenuComponent
        PopupMenu {
            model: [
                {id: "a", text: "Plain"},
                {id: "b", text: "With icon", iconName: "lock"},
                {separator: true},
                {id: "c", text: "Checked", checked: true},
                {id: "d", text: "Unchecked", checked: false},
                {separator: true},
                {id: "e", text: "After"}
            ]
        }
    }

    function test_labelsFollowTheirRowAndSection() {
        const m = createTemporaryObject(layoutMenuComponent, testCase);
        wait(0);
        // The label Text of a row (a MenuItem carries the same `text`, so look for the QQuickText itself).
        const label = (root, name) => {
            for (const child of root.children) {
                if (String(child).indexOf("QQuickText") === 0 && child.text === name)
                    return child;
                const found = label(child, name);
                if (found)
                    return found;
            }
            return null;
        };
        const left = name => {
            const t = label(m, name);
            verify(t !== null, name);
            return t.mapToItem(m, 0, 0).x;
        };
        compare(left("Plain"), Tokens.menuPadding + Tokens.menuItemPadding);
        compare(left("With icon"), Tokens.menuPadding + Tokens.menuItemPadding + Tokens.menuIconSize + Tokens.spacingSm);
        compare(left("Checked"), Tokens.menuPadding + Tokens.menuCheckInset);
        compare(left("Unchecked"), Tokens.menuPadding + Tokens.menuCheckInset, "the whole section aligns after the check column");
        compare(left("After"), Tokens.menuPadding + Tokens.menuItemPadding, "the next section has no check column");
        verify(Math.abs(m.width - Math.round(m.width)) < 1e-9, "whole-pixel width " + m.width);
    }

    function test_highlightIsConcentricWithTheMenu() {
        const row = createTemporaryObject(itemComponent, testCase, {text: "Open", highlighted: true});
        let fill = null;
        for (const child of row.children) {
            if (String(child).indexOf("QQuickRectangle") === 0 && child.visible)
                fill = child;
        }
        verify(fill !== null);
        compare(fill.radius, Tokens.radiusMenu - Tokens.menuPadding);
        compare(fill.color, Qt.color(Appearance.colors.selection));
    }

    function test_downSkipsDisabledAndSeparator() {
        const m = makeMenu();
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 0);
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 3);
    }

    function test_returnActivatesCurrent() {
        const m = makeMenu();
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "a");
    }

    function test_escapeRequestsClose() {
        makeMenu();
        keyClick(Qt.Key_Escape);
        compare(closeSpy.count, 1);
    }

    function test_disabledNeverActivates() {
        const m = makeMenu();
        m.currentIndex = 2;
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 0);
    }

    function test_submenuOpensAndActivates() {
        const m = makeMenu();
        keyClick(Qt.Key_Up);
        compare(m.currentIndex, 4);
        compare(m.extent.width, m.width);
        keyClick(Qt.Key_Right);
        compare(m.openIndex, 4);
        wait(100);
        // A host sized by extent (the desktop's PopupWindow) includes the submenu, which opens to the right.
        const sub = m.submenuItem;
        compare(m.extent.width, sub.mapToItem(m, sub.width, 0).x);
        verify(m.extent.width > m.width);
        verify(m.extent.height >= m.height);
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "d2");
    }

    // Swatch rows (Files colour tags): the keyboard reaches the row, Left/Right pick a swatch, Return activates the
    // swatch itself; a disabled row is skipped and shows its reason; a click on a swatch activates it.
    function test_swatchRowKeyboard() {
        const m = createTemporaryObject(swatchMenuComponent, testCase);
        m.forceActiveFocus();
        activatedSpy.target = m;
        activatedSpy.clear();
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 1);
        compare(m.swatchIndex, 0);
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Right);
        compare(m.swatchIndex, 2);
        keyClick(Qt.Key_Right);
        compare(m.swatchIndex, 0, "wraps");
        keyClick(Qt.Key_Left);
        compare(m.swatchIndex, 2);
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "tag:2");
        // Down skips the disabled row.
        keyClick(Qt.Key_Down);
        compare(m.currentIndex, 3);
    }

    function test_swatchRowPointer() {
        const m = createTemporaryObject(swatchMenuComponent, testCase);
        activatedSpy.target = m;
        activatedSpy.clear();
        waitForRendering(m);
        // The second swatch of the tags row (row 1, under the one-line "Open" row): menu padding, the row's padding and
        // the ring around each swatch.
        const step = Tokens.menuSwatchSize + 2 * Tokens.menuSwatchRing + Tokens.menuSwatchGap;
        const p = Qt.point(Tokens.menuPadding + Tokens.menuItemPadding + step + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2,
                           Tokens.menuPadding + Tokens.menuItemHeight + Tokens.spacingXs + Tokens.menuSwatchRing + Tokens.menuSwatchSize / 2);
        mouseMove(m, p.x - 1, p.y);
        mouseMove(m, p.x, p.y);
        compare(m.currentIndex, 1);
        compare(m.swatchIndex, 1);
        mouseClick(m, p.x, p.y);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "tag:1");
    }

    // ---- pointer relay: press, drag, release with the pointer held by another surface (the menu bar) ----

    // Centre of the row showing `text`, in scene coordinates (what the menu bar reports).
    function centreOf(root: Item, text: string): point {
        const row = textItem(root, text);
        verify(row !== null, "no row " + text);
        return row.mapToItem(null, row.width / 2, row.height / 2);
    }

    function test_relayRowAt() {
        const m = makeMenu();
        wait(50);
        compare(m.rowAt(centreOf(m, "Alpha").x, centreOf(m, "Alpha").y), 0);
        compare(m.rowAt(centreOf(m, "Gamma").x, centreOf(m, "Gamma").y), 3);
        compare(m.rowAt(centreOf(m, "Delta").x, centreOf(m, "Delta").y), 4);
        // A disabled row, the separator and the outside are no row.
        compare(m.rowAt(centreOf(m, "Beta").x, centreOf(m, "Beta").y), -1);
        const sep = centreOf(m, "Alpha");
        compare(m.rowAt(sep.x, sep.y + (centreOf(m, "Beta").y - sep.y) / 2), -1);
        compare(m.rowAt(-50, -50), -1);
        compare(m.rowAt(m.mapToItem(null, 0, 0).x + m.width + 40, sep.y), -1);
        verify(m.containsPoint(sep.x, sep.y));
        verify(!m.containsPoint(-50, -50));
    }

    function test_relayTrackHighlightsTheRowUnderThePointer() {
        const m = makeMenu();
        wait(50);
        m.trackPointer(centreOf(m, "Gamma").x, centreOf(m, "Gamma").y);
        compare(m.currentIndex, 3);
        m.trackPointer(centreOf(m, "Alpha").x, centreOf(m, "Alpha").y);
        compare(m.currentIndex, 0);
        // A disabled row and the outside clear the highlight (the pointer is on no row), nothing runs.
        m.trackPointer(centreOf(m, "Beta").x, centreOf(m, "Beta").y);
        compare(m.currentIndex, -1);
        m.trackPointer(centreOf(m, "Gamma").x, centreOf(m, "Gamma").y);
        m.trackPointer(-30, -30);
        compare(m.currentIndex, -1);
        compare(activatedSpy.count, 0);
    }

    function test_relayReleaseRunsTheRowUnderThePointer() {
        const m = makeMenu();
        wait(50);
        const p = centreOf(m, "Gamma");
        m.trackPointer(p.x, p.y);
        verify(m.releasePointer(p.x, p.y));
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "c");
        compare(closeSpy.count, 0);
    }

    function test_relayReleaseOutsideARowLeavesTheMenuOpen() {
        const m = makeMenu();
        wait(50);
        const beta = centreOf(m, "Beta");
        verify(!m.releasePointer(beta.x, beta.y));
        verify(!m.releasePointer(-20, -20));
        // Back on the bar title (above the menu): nothing either.
        verify(!m.releasePointer(m.mapToItem(null, 0, 0).x + 5, m.mapToItem(null, 0, 0).y - 10));
        compare(activatedSpy.count, 0);
        compare(closeSpy.count, 0);
    }

    function test_relaySubmenuRowOpensItAndRunsItsRows() {
        const m = makeMenu();
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        compare(m.openIndex, 4);
        wait(100);
        const sub = m.submenuItem;
        verify(sub !== null);
        const one = centreOf(sub, "Delta one");
        verify(m.containsPoint(one.x, one.y));
        // The pointer moves into the submenu: its row is highlighted, the parent keeps the open row.
        m.trackPointer(one.x, one.y);
        compare(sub.currentIndex, 0);
        compare(m.currentIndex, 4);
        compare(m.openIndex, 4);
        const two = centreOf(sub, "Delta two");
        m.trackPointer(two.x, two.y);
        compare(sub.currentIndex, 1);
        // Released on a submenu row: that row runs.
        verify(m.releasePointer(two.x, two.y));
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "d2");
    }

    function test_relayReleaseOnASubmenuRowKeepsTheMenuOpen() {
        const m = makeMenu();
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        wait(100);
        verify(m.releasePointer(d.x, d.y));
        compare(activatedSpy.count, 0);
        compare(m.openIndex, 4);
        compare(closeSpy.count, 0);
    }

    function test_relayMovingToAPlainRowClosesTheSubmenu() {
        const m = makeMenu();
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        compare(m.openIndex, 4);
        const g = centreOf(m, "Gamma");
        m.trackPointer(g.x, g.y);
        compare(m.openIndex, -1);
        compare(m.currentIndex, 3);
    }

    function test_leftClosesSubmenu() {
        const m = makeMenu();
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Right);
        wait(100);
        keyClick(Qt.Key_Left);
        compare(m.openIndex, -1);
        compare(closeSpy.count, 0);
    }

    // Option (Alt) variants (macOS Dock menu): the menu reports whether Alt is down, live, and nothing else changes.
    function test_altHeldFollowsTheKey() {
        const m = makeMenu();
        verify(!m.altHeld);
        keyClick(Qt.Key_Down);
        keyPress(Qt.Key_Alt, Qt.AltModifier);
        verify(m.altHeld);
        compare(m.currentIndex, 0);
        compare(activatedSpy.count, 0);
        compare(closeSpy.count, 0);
        keyRelease(Qt.Key_Alt, Qt.NoModifier);
        verify(!m.altHeld);
    }

    function test_altHeldReachesTheTopMenuFromASubmenu() {
        const m = makeMenu();
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Right);
        wait(100);
        verify(m.openIndex >= 0);
        keyPress(Qt.Key_Alt, Qt.AltModifier);
        verify(m.altHeld);
        keyRelease(Qt.Key_Alt, Qt.NoModifier);
        verify(!m.altHeld);
    }

    SignalSpy {
        id: stepSpy
        signalName: "menuStepRequested"
    }

    // GF-002 (audit): Right and Left in an open bar menu ask the bar for the next or previous title, also with the host's
    // `bounds` set (the overlay sets it on every menu) and with no row selected (a menu opened with the pointer).
    function test_rightAndLeftStepTheBarMenus() {
        const m = makeMenu();
        m.bounds = testCase;
        m.currentIndex = -1;
        stepSpy.target = m;
        stepSpy.clear();
        keyClick(Qt.Key_Right);
        compare(stepSpy.count, 1);
        compare(stepSpy.signalArguments[0][0], 1);
        keyClick(Qt.Key_Left);
        compare(stepSpy.count, 2);
        compare(stepSpy.signalArguments[1][0], -1);
    }

    // macOS: no row is highlighted when a menu opens, and a submenu opened by the pointer has none either, until the pointer
    // or a key selects one (a submenu opened with Right or Return highlights its first row).
    function test_noHighlightUntilSelected() {
        const m = makeMenu();
        compare(m.currentIndex, -1);
        wait(50);
        const d = centreOf(m, "Delta");
        m.trackPointer(d.x, d.y);
        compare(m.openIndex, 4);
        wait(100);
        compare(m.submenuItem.currentIndex, -1);
        m.closeSubmenu();
        m.currentIndex = 4;
        keyClick(Qt.Key_Right);
        wait(100);
        compare(m.submenuItem.currentIndex, 0);
    }
}
