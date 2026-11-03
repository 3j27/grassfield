import QtQuick
import QtTest
import Grassfield.Ui

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
        compare(back.glyphOpacity, Tokens.controlToolGlyphOpacity);
        verify(back.glyphOpacity > 0.7 && back.glyphOpacity < 1);
        const on = find(back.contentItem, i => i.forward !== undefined && i.width === Tokens.toolbarNavChevronWidth);
        const off = find(forward.contentItem, i => i.forward !== undefined && i.width === Tokens.toolbarNavChevronWidth);
        compare(on.opacity, Tokens.controlToolGlyphOpacity);
        verify(Qt.colorEqual(on.color, Appearance.colors.text), "enabled: the text colour, dimmed by the opacity");
        verify(off.color.a < on.color.a, "disabled: lighter");
        compare(off.color.a, Tokens.materialDisabledOpacity);
    }
}
