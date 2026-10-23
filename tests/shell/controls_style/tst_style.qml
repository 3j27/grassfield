import QtQuick
import QtQuick.Controls
import QtTest

// Run by tests/shell/controls_style.sh with QT_QUICK_CONTROLS_STYLE=Grassfield: the stock Controls resolve to the Grassfield
// style (ui/Grassfield), i.e. to Grassfield.Ui controls, which carry properties the stock ones do not have.
TestCase {
    name: "ControlsStyle"
    width: 300
    height: 200
    visible: true
    when: windowShown

    Column {
        Button {
            id: button
            text: "Go"
        }

        ToolButton {
            id: tool
        }

        ComboBox {
            id: combo
        }

        CheckBox {
            id: check
        }

        TextField {
            id: field
        }

        Slider {
            id: slider
        }
    }

    function test_stockControlsAreGrassfields() {
        verify(button.primary !== undefined, "Button is Ui.Button (has `primary`)");
        verify(tool.radio !== undefined, "ToolButton is Ui.ToolButton");
        verify(combo.accessibleName !== undefined, "ComboBox is Ui.ComboBox");
        verify(check.accessibleName !== undefined, "CheckBox is Ui.CheckBox");
        verify(field.accessibleName !== undefined, "TextField is Ui.TextField");
        compare(button.height, 32, "Ui.Button default height (menuItemHeight + spacing.sm)");
    }

    function test_uncoveredControlsFallBack() {
        verify(slider.value !== undefined, "Slider falls back to the fallback style and still works");
        verify(slider.primary === undefined);
    }
}
