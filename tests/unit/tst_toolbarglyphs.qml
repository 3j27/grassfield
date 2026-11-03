import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml" as FilesQml

// Toolbar glyphs (refinement batch 6): 18 pt boxes, a dark grey rather than the full text colour, and Back / Forward as an
// 8 x 14 pt drawn chevron (macOS 27: ss-004-005, gs-010-011).
TestCase {
    id: tc
    name: "ToolbarGlyphs"
    width: 200
    height: 80
    visible: true
    when: windowShown

    Row {
        ToolButton {
            id: back
            capsule: true
            buttonSize: Tokens.toolbarGroupButton
            navigation: "back"
            accessibleName: "Back"
        }

        ToolButton {
            id: forward
            capsule: true
            buttonSize: Tokens.toolbarGroupButton
            navigation: "forward"
            enabled: false
            accessibleName: "Forward"
        }

        ToolButton {
            id: hosted
            accessibleName: "Hosted"

            FilesQml.ViewGlyph {
                id: hostedGlyph
                anchors.centerIn: parent
                kind: "columns"
            }
        }

        ToolButton {
            id: plain
            iconName: "gear"
            accessibleName: "Settings"
        }
    }

    function find(root, test) {
        const stack = [root];
        while (stack.length > 0) {
            const it = stack.shift();
            if (test(it))
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_theSizesAreTheMeasuredOnes() {
        compare(Tokens.controlToolIconSize, 18);
        compare(Tokens.filesToolbarIconSize, 18);
        compare(Tokens.previewToolbarIconSize, 18);
        compare(Tokens.toolbarNavChevronWidth, 8);
        compare(Tokens.toolbarNavChevronHeight, 14);
        compare(Tokens.toolbarNavChevronStroke, 1.5);
        compare(plain.glyphSize, 18);
    }

    function test_backAndForwardDrawTheChevronNotAnIcon() {
        const chevron = find(back.contentItem, i => i.forward !== undefined && i.width === Tokens.toolbarNavChevronWidth);
        verify(chevron !== null, "a NavChevron in Back");
        verify(chevron.visible && !chevron.forward);
        compare(chevron.height, Tokens.toolbarNavChevronHeight);
        const ahead = find(forward.contentItem, i => i.forward !== undefined && i.width === Tokens.toolbarNavChevronWidth);
        verify(ahead !== null && ahead.forward, "Forward points right");
        const icon = find(back.contentItem, i => i.name !== undefined && i.directory !== undefined);
        verify(icon !== null && !icon.visible, "no symbolic icon behind it");
    }

    function test_glyphsAreDarkGreyAndADisabledOneLighter() {
        const on = find(back.contentItem, i => i.forward !== undefined && i.width === Tokens.toolbarNavChevronWidth);
        const off = find(forward.contentItem, i => i.forward !== undefined && i.width === Tokens.toolbarNavChevronWidth);
        compare(on.opacity, 1, "the dimming is in the colour, not an item opacity");
        verify(Qt.colorEqual(Qt.rgba(on.color.r, on.color.g, on.color.b, 1), Appearance.colors.text), "enabled: the text colour");
        fuzzyCompare(on.color.a, Tokens.controlToolGlyphOpacity, 0.01);
        verify(off.color.a < on.color.a, "disabled: lighter");
        fuzzyCompare(off.color.a, Tokens.controlToolGlyphOpacity * Tokens.materialDisabledOpacity, 0.01);
    }

    // Qt applies an item's opacity to each part of a glyph drawn from several items, so their overlaps would draw darker: the
    // slot never has an opacity, and the host's glyph takes the dimming in its colour.
    function test_aHostDrawnGlyphIsDimmedInItsColourNotByAnOpacity() {
        compare(hostedGlyph.parent.opacity, 1, "the slot opacity is 1");
        compare(hostedGlyph.opacity, 1);
        verify(Qt.colorEqual(hostedGlyph.color, hosted.glyphColor), "the glyph takes the button's glyph colour by default");
        fuzzyCompare(hostedGlyph.color.a, Tokens.controlToolGlyphOpacity, 0.01);
        // The columns' dividers lie inside the frame's outline: no overlap.
        const dividers = find(hostedGlyph, i => i.height !== undefined && i.y === Tokens.filesViewGlyphStroke && i.width === Tokens.filesViewGlyphStroke);
        verify(dividers !== null, "a divider starts inside the frame");
    }

    function test_theGlyphColourFollowsTheButtonsState() {
        const live = Appearance.withAlpha(Appearance.colors.text, Tokens.controlToolGlyphOpacity);
        verify(Qt.colorEqual(plain.glyphColor, live));
        plain.enabled = false;
        const disabled = Appearance.withAlpha(Appearance.colors.text, Tokens.controlToolGlyphOpacity * Tokens.materialDisabledOpacity);
        fuzzyCompare(plain.glyphColor.a, disabled.a, 0.01);
        plain.enabled = true;
        // Disabled and not key dim together, never to a darker glyph than an enabled one.
        verify(plain.dimAlpha <= 1);
    }
}
