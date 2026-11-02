import QtQuick
import QtTest
import Grassfield.Ui

// Hover and selection roles (ADR-0039 step 12, G6; docs/audits/design-polish-2026-10-29.md § 3.10): one token per role where
// eight fills stood in for three. macOS 27 draws a light hover on a control, a neutral selection of an item on glass (its App
// Switcher: black at 0.25, #ACACAC on #E5E5E5) and the accent in menus. The surfaces that carried multipliers of the panel
// fill or a rim token (the stack popup, the Overview's minimized windows, the switcher, the tiling suggestions) need
// Quickshell: their sources are read here, the token is measured.
TestCase {
    name: "SelectionRoles"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    readonly property string selection: "Appearance.withAlpha(Appearance.colors.hover, Tokens.materialSelectionOpacity)"

    function channel(v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    function lum(c) {
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }

    // `ink` at `alpha` over the opaque `base`.
    function over(ink, alpha, base) {
        const a = Qt.color(ink), b = Qt.color(base);
        return Qt.rgba(a.r * alpha + b.r * (1 - alpha), a.g * alpha + b.g * (1 - alpha), a.b * alpha + b.b * (1 - alpha), 1);
    }

    function ratio(a, b) {
        const la = lum(a), lb = lum(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function test_theSelectionToken() {
        compare(Tokens.materialSelectionOpacity, 0.25, "macOS 27's App Switcher");
        verify(Tokens.materialSelectionOpacity > Tokens.materialHoverOpacity, "a selection reads stronger than a hover");
        // macOS 27 measures 1.8:1 on its glass; on the opaque material tint of each appearance the role reads at least as much.
        for (const palette of [Tokens.colorLight, Tokens.colorDark]) {
            const r = ratio(over(palette.hover, Tokens.materialSelectionOpacity, palette.materialTint), Qt.color(palette.materialTint));
            verify(r >= 1.7, palette.materialTint + ": " + r.toFixed(2));
        }
    }

    function test_theSurfacesTakeTheRole_data() {
        return [
            {tag: "the switcher's tile", path: "shell/switcher/SwitcherWindow.qml", count: 1},
            {tag: "the stack grid's cell", path: "shell/overlay/StackPopup.qml", count: 1},
            {tag: "an Overview Desktop tile and minimized window", path: "shell/overview/OverviewWindow.qml", count: 2},
            {tag: "the tiling suggestions' window", path: "shell/overlay/TilingSuggestions.qml", count: 1}
        ];
    }

    function test_theSurfacesTakeTheRole(data) {
        const text = source(data.path);
        compare(text.split(tc_selection()).length - 1, data.count, data.tag + " takes the neutral selection");
        verify(!/Tokens\.materialFillOpacity \*/.test(text), data.path + " multiplies the panel fill no more");
        verify(text.indexOf("Tokens.materialHighlightOpacity") < 0, data.path + " borrows the rim token no more");
        verify(text.indexOf("withAlpha(Appearance.colors.text, Tokens.materialHoverOpacity)") < 0, data.path + ": no text-coloured highlight");
    }

    function tc_selection() {
        return selection;
    }

    function test_theStacksBackRowIsAControl() {
        const text = source("shell/overlay/StackPopup.qml");
        const start = text.indexOf("id: backRow");
        const end = text.indexOf("Icon {", start);
        verify(start >= 0 && end > start);
        const row = text.slice(start, end);
        verify(row.indexOf("color: Appearance.buttonFill") >= 0, "the control fill");
        verify(row.indexOf("color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)") >= 0, "the control hover");
        verify(row.indexOf("visible: backMouse.containsMouse") >= 0, "under the pointer");
    }
}
