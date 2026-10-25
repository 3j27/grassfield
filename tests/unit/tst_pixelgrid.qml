import QtQuick
import QtTest
import Grassfield.Ui

// The shared controls draw their edges on whole pixels at scale 1 (ADR-0024, docs/audits/ui-finesse-2026-10-25.md F5): a
// rectangle, image or effect whose scene position or size has a fraction is drawn as a soft half-tone column or row on a
// 1x screen. Laid out as hosts lay them out (rows of text-sized controls, a menu with right-aligned shortcuts, the window
// lights). Text is not checked (its glyphs are placed at fractional positions by design), nor a slider's value-dependent fill
// and knob.
TestCase {
    id: tc

    name: "PixelGrid"
    width: 900
    height: 560
    visible: true
    when: windowShown

    Item {
        id: scene
        anchors.fill: parent

        PopupMenu {
            id: menu
            x: 24
            y: 24
            currentIndex: 2
            model: [
                {id: "a", text: "About This Computer"},
                {separator: true},
                {id: "b", text: "Settings…", shortcut: "Ctrl+,"},
                {id: "c", text: "App Store…", enabled: false},
                {separator: true},
                {id: "d", text: "Recent Items", submenu: [{id: "x", text: "x"}]},
                {separator: true},
                {id: "f", text: "Sleep"},
                {id: "g", text: "Show Hidden Files", checked: true},
                {id: "h", text: "Lock Screen", shortcut: "Super+L", iconName: "lock"},
                {id: "i", text: "Log Out…", shortcut: "Shift+Super+Q"}
            ]
        }

        Column {
            x: 330
            y: 24
            spacing: 14

            Row {
                spacing: 12
                Button { text: "Cancel"; push: true }
                Button { text: "OK"; push: true; primary: true }
                Button { text: "Default" }
                Button { text: "Delete"; capsule: true }
            }
            Row {
                spacing: 16
                Toggle { checked: true }
                Switch { checked: false }
                CheckBox { checked: true; text: "Check" }
                RadioButton { checked: true; text: "Radio" }
            }
            SegmentedControl {
                model: [{id: "l", text: "Light"}, {id: "d", text: "Dark"}, {id: "a", text: "Auto"}]
                value: "l"
            }
            TextField { width: 220; text: "Field text" }
            SearchField { width: 220 }
            ComboBox { width: 180; model: [{id: "a", text: "Automatic"}]; value: "a" }
            Row {
                spacing: 12
                WindowControls { style: "unified" }
                WindowControls { style: "titlebar" }
            }
        }

        Material {
            x: 600
            y: 330
            width: 260
            height: 180
            radius: 26
        }
    }

    function frac(v) {
        return Math.abs(v - Math.round(v)) > 0.01;
    }

    function draws(item) {
        const s = String(item);
        if (s.indexOf("QQuickRectangle") === 0)
            return (item.color.a > 0.01) || (item.border.width > 0 && item.border.color.a > 0.01);
        return s.indexOf("QQuickImage") === 0 || s.indexOf("QQuickMultiEffect") === 0;
    }

    function offGrid(item, out) {
        if (!item.visible || item.opacity === 0 || String(item).indexOf("Slider") === 0)
            return;
        if (draws(item)) {
            const p = item.mapToItem(scene, 0, 0);
            if (frac(p.x) || frac(p.y) || frac(item.width) || frac(item.height))
                out.push(String(item).split("(")[0] + " at " + p.x + "," + p.y + " size " + item.width + "x" + item.height + " in " + String(item.parent).split("(")[0]);
        }
        for (let i = 0; i < item.children.length; i++)
            offGrid(item.children[i], out);
    }

    function test_sharedControlsDrawOnWholePixels() {
        wait(50);
        const out = [];
        offGrid(scene, out);
        compare(out.length, 0, "drawn off the pixel grid: " + out.join("; "));
    }

    function test_menuWidthIsWhole() {
        verify(!frac(menu.width), "menu width " + menu.width);
    }

    function test_unifiedLightsAreWhole() {
        // macOS 27 measures the first centre at (26.0, 25.5-25.75); 26 keeps the 14-pt discs on whole pixels.
        compare(Tokens.windowUnifiedLightCentre, 26);
    }
}
