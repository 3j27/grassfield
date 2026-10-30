import QtQuick
import QtTest
import Grassfield.Ui

// Increase Contrast outlines every shared control (ADR-0039 step 1, G8 and G9): the switches' and the slider's tracks too, and
// the settings-row pop-up outlines its chevron disc, never a box around its value (the value starts at the pop-up's edge, so a
// box cut into its first letter: "Icon theme" read "|con theme"). Without the setting none of them draws an outline.
TestCase {
    id: tc

    name: "IncreaseContrast"
    width: 400
    height: 300
    visible: true
    when: windowShown

    Column {
        spacing: 12

        Toggle { id: toggleOff; checked: false }
        Toggle { id: toggleOn; checked: true }
        Switch { id: switchOff; checked: false }
        Slider { id: slider; width: 200; value: 0.5 }
        Slider { id: knobless; width: 200; value: 0.5; knobless: true }
        ComboBox { id: form; width: 180; model: [{id: "a", text: "Automatic"}]; value: "a" }
        ComboBox { id: rowPopUp; inline: true; model: [{id: "a", text: "Icon theme"}]; value: "a" }
    }

    function init() {
        Appearance.increaseContrast = false;
    }

    function cleanup() {
        Appearance.increaseContrast = false;
    }

    // The visible rectangle of `item` as wide as the control: a switch's or a slider's track, a pop-up's bezel.
    function track(item, width) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it !== item && it.visible && String(it).indexOf("QQuickRectangle") === 0 && Math.abs(it.width - width) < 0.01)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // The control outline of Increase Contrast: the material border colour at the border opacity. (A Rectangle reports a
    // 1-wide black border even when it draws none, so the width alone does not tell.)
    function outlined(rect) {
        return rect.border.width === Tokens.controlBorderWidth
            && Qt.colorEqual(rect.border.color, Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity));
    }

    function test_switchesAndSlidersAreOutlinedOnlyUnderIncreaseContrast_data() {
        return [
            {tag: "toggle off", control: toggleOff},
            {tag: "toggle on", control: toggleOn},
            {tag: "switch off", control: switchOff},
            {tag: "slider", control: slider},
            {tag: "knobless slider", control: knobless}
        ];
    }

    function test_switchesAndSlidersAreOutlinedOnlyUnderIncreaseContrast(data) {
        const t = track(data.control, data.control.width);
        verify(t !== null, "track of " + data.tag);
        verify(!outlined(t), data.tag + " outlined without Increase Contrast");
        Appearance.increaseContrast = true;
        verify(outlined(t), data.tag + " not outlined under Increase Contrast");
    }

    function test_formPopUpKeepsItsBezelOutline() {
        const bezel = form.background as Rectangle;
        verify(!outlined(bezel));
        Appearance.increaseContrast = true;
        verify(outlined(bezel));
    }

    function test_inlinePopUpOutlinesItsDiscNotItsValue() {
        const bezel = rowPopUp.background as Rectangle;
        const disc = rowPopUp.indicator.children[0] as Rectangle;
        verify(disc.visible);
        verify(!outlined(bezel) && !outlined(disc));
        Appearance.increaseContrast = true;
        verify(!outlined(bezel), "no box around the value: it starts at the pop-up's edge");
        verify(outlined(disc), "the chevron disc carries the outline");
    }

    function test_inlinePopUpDiscIsOnWholePixels() {
        // settings.popupInset is a measured 3.5: the disc is rounded onto the pixel grid, within half a point of it.
        verify(rowPopUp.width === Math.round(rowPopUp.width), "pop-up width " + rowPopUp.width);
        const x = rowPopUp.indicator.x;
        compare(x, Math.round(x));
        verify(Math.abs(rowPopUp.width - x - Tokens.settingsPopupIndicatorSize - Tokens.settingsPopupInset) <= 0.5,
               "disc inset " + (rowPopUp.width - x - Tokens.settingsPopupIndicatorSize));
    }
}
