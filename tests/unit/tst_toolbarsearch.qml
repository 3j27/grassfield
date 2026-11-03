import QtQuick
import QtTest
import Grassfield.Ui

// The shared toolbar and search field (ADR-0039 step 14): the toolbar's tokens are one group (toolbar.*, where Settings, the
// Store and Activity Monitor borrowed files.* and settings.*); SearchField is the rimmed 28-pt glass capsule with its glyph and
// a clear button, used by Settings; a text field's placeholder shows (the template draws none); an icon-only ToolButton names
// itself in a tooltip after the shared delay, a captioned one does not, and a host can turn it off.
TestCase {
    id: tc

    name: "ToolbarSearch"
    width: 400
    height: 240
    visible: true
    when: windowShown

    SearchField {
        id: search
        y: 10
        width: 220
    }

    TextField {
        id: field
        y: 50
        width: 220
        placeholderText: "~/Documents"
    }

    Row {
        y: 100
        x: 150
        spacing: 20

        ToolButton {
            id: iconOnly
            iconName: "chevron-right"
            accessibleName: "Forward"
        }

        ToolButton {
            id: captioned
            text: "Done"
        }

        ToolButton {
            id: silenced
            iconName: "chevron-right"
            accessibleName: "Stop"
            tooltip: ""
        }
    }

    function cleanup() {
        search.text = "";
        field.text = "";
        mouseMove(tc, tc.width - 2, tc.height - 2);
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

    function test_theToolbarTokens() {
        compare(Tokens.toolbarCapsule, 36);
        compare(Tokens.toolbarGroupButton, 34);
        compare(Tokens.toolbarSearchHeight, 28);
        compare(Tokens.toolbarDividerHeight, 20);
    }

    function test_theSearchFieldIsTheRimmedCapsule() {
        compare(search.height, Tokens.toolbarSearchHeight);
        const capsule = search.background as RimmedCapsule;
        verify(capsule !== null, "the background is the rimmed capsule");
        compare(capsule.radius, search.height / 2, "a capsule");
        compare(capsule.fillOpacity, Tokens.toolbarFieldFillOpacity, "the rimmed glass fill");
        verify(capsule.field, "a flat field: no shadow");
        compare(capsule.border.width, Appearance.increaseContrast ? Tokens.controlBorderWidth : 0, "no outline in the standard appearance");
        // The clear button shows with text only, and clears it.
        const clear = find(search, it => it.objectName === "clearButton");
        verify(clear !== null);
        verify(!clear.visible);
        search.text = "dock";
        verify(clear.visible);
        mouseClick(clear);
        compare(search.text, "", "the clear button clears");
    }

    function test_aPlaceholderShowsWhileEmpty_data() {
        return [{tag: "a search field", control: search, hint: "Search"}, {tag: "a text field", control: field, hint: "~/Documents"}];
    }

    function test_aPlaceholderShowsWhileEmpty(data) {
        const hint = find(data.control, it => it.objectName === "placeholder");
        verify(hint !== null, "the field draws its placeholder");
        compare(hint.text, data.hint);
        verify(hint.visible, "empty: the hint shows");
        verify(Qt.colorEqual(hint.color, Appearance.colors.textSecondary), "in the secondary colour");
        data.control.text = "x";
        verify(!hint.visible, "typed: the hint hides");
    }

    function tipOf(button) {
        return find(button.Window.contentItem, it => it.text === button.tooltip && it.shown !== undefined && it.delay !== undefined);
    }

    function test_anIconOnlyButtonNamesItself() {
        compare(iconOnly.tooltip, "Forward");
        compare(captioned.tooltip, "", "a captioned button needs no tooltip");
        compare(silenced.tooltip, "", "a host can turn it off");
        mouseMove(iconOnly, iconOnly.width / 2, iconOnly.height / 2);
        const tip = tipOf(iconOnly);
        verify(tip !== null, "the tooltip lives over the window's content");
        tryVerify(() => tip.visibleNow, Tokens.controlTooltipDelay * 4, "it shows after the delay");
        const at = tip.mapToItem(iconOnly, tip.width / 2, 0);
        verify(Math.abs(at.x - iconOnly.width / 2) < 1, "centred under the button: " + at.x);
        verify(at.y >= iconOnly.height, "under it");
        mouseMove(tc, tc.width - 2, tc.height - 2);
        tryVerify(() => !tip.visibleNow, Tokens.controlTooltipDelay * 4, "it hides when the pointer leaves");
    }

    Component {
        id: edgeButton
        ToolButton {
            x: 0
            y: 180
            iconName: "chevron-right"
            accessibleName: "A rather long name at the edge"
        }
    }

    // At the window's edge the tooltip stays inside the window.
    function test_theTooltipStaysInTheWindow() {
        const b = createTemporaryObject(edgeButton, tc);
        mouseMove(b, b.width / 2, b.height / 2);
        const tip = tipOf(b);
        verify(tip !== null);
        tryVerify(() => tip.visibleNow, Tokens.controlTooltipDelay * 4);
        verify(tip.x >= 0, "not past the left edge: " + tip.x);
        verify(tip.x + tip.width <= tip.parent.width, "not past the right edge");
    }
}
