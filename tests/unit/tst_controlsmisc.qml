import QtQuick
import QtTest
import Grassfield.Ui

// SegmentedControl, ComboBox, ProgressBar, ScrollBar, Sheet and Slider of Grassfield.Ui on QtQuick.Templates (GF-085).
TestCase {
    id: tc

    name: "ControlsMisc"
    width: 500
    height: 500
    visible: true
    when: windowShown

    property var picks: []
    property int moves: 0

    Item {
        id: stage
        anchors.fill: parent

        Column {
            spacing: 8

            SegmentedControl {
                id: seg
                model: [{id: "a", text: "Alpha"}, {id: "b", text: "Beta"}, {id: "c", text: "Gamma"}]
                value: "b"
                accessibleName: "Letters"
                onPicked: id => tc.picks.push(id)
            }

            ComboBox {
                id: combo
                model: [{id: "x", text: "Ex"}, {id: "y", text: "Why"}]
                value: "x"
                accessibleName: "Pick"
                onPicked: id => tc.picks.push(id)
            }

            ProgressBar {
                id: bar
                from: 0
                to: 10
                value: 5
                accessibleName: "Copy"
            }

            Slider {
                id: slider
                value: 0.5
                accessibleName: "Level"
                onMoved: v => tc.moves++
            }

            Item {
                width: 100
                height: 100

                Flickable {
                    id: flick
                    anchors.fill: parent
                    contentWidth: 100
                    contentHeight: 400
                }

                ScrollBar {
                    id: scroll
                    flickable: flick
                    anchors.right: parent.right
                    height: parent.height
                }
            }
        }

        Sheet {
            id: sheet
            title: "Go to"
            withField: true
            confirmHandler: text => text === "bad" ? "No such folder" : ""
        }
    }

    function init() {
        tc.picks = [];
        tc.moves = 0;
        seg.value = "b";
        combo.value = "x";
        sheet.visible = false;
    }

    function test_segmentedKeysReportButDoNotMoveTheValue() {
        seg.forceActiveFocus();
        keyClick(Qt.Key_Right);
        compare(tc.picks, ["c"]);
        compare(seg.value, "b", "the host owns the value");
        keyClick(Qt.Key_Left);
        compare(tc.picks, ["c", "a"]);
        seg.value = "c";
        keyClick(Qt.Key_Right);
        compare(tc.picks.length, 2, "no step past the end");
    }

    function test_segmentedAccessibility() {
        compare(seg.Accessible.role, Accessible.Grouping);
        compare(seg.Accessible.name, "Letters");
        compare(seg.Accessible.description, "Beta");
        compare(seg.currentIndex, 1);
        const row = seg.contentItem;
        const seg0 = row.children[0];
        compare(seg0.Accessible.role, Accessible.RadioButton);
        compare(seg0.Accessible.checked, false);
        compare(row.children[1].Accessible.checked, true);
        seg0.Accessible.pressAction();
        compare(tc.picks, ["a"]);
    }

    function test_accessibilityPressIsGuarded() {
        const seg0 = seg.contentItem.children[0];
        seg.enabled = false;
        seg0.Accessible.pressAction();
        compare(tc.picks, [], "a disabled SegmentedControl never picks on an accessibility press");
        seg.enabled = true;
        seg.visible = false;
        seg0.Accessible.pressAction();
        compare(tc.picks, [], "a hidden one neither");
        seg.visible = true;
        combo.enabled = false;
        combo.Accessible.pressAction();
        verify(!combo.open, "a disabled ComboBox does not open on an accessibility press");
        combo.enabled = true;
        combo.visible = false;
        combo.Accessible.pressAction();
        verify(!combo.open, "a hidden one neither");
        combo.visible = true;
        combo.Accessible.pressAction();
        tryCompare(combo, "open", true);
        combo.popup.close();
        tryCompare(combo, "open", false);
        slider.enabled = false;
        slider.Accessible.increaseAction();
        compare(tc.moves, 0, "a disabled Slider ignores an accessibility increase");
        slider.enabled = true;
        slider.Accessible.increaseAction();
        compare(tc.moves, 1);
    }

    function test_segmentedClickPicks() {
        const row = seg.contentItem;
        mouseClick(row.children[2]);
        compare(tc.picks, ["c"]);
    }

    function test_comboShowsTheValueAndOpensWithKeys() {
        compare(combo.displayText, "Ex");
        compare(combo.Accessible.role, Accessible.ComboBox);
        combo.forceActiveFocus();
        keyClick(Qt.Key_Down);
        tryCompare(combo, "open", true);
        combo.popup.close();
        tryCompare(combo, "open", false);
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        combo.popup.close();
        tryCompare(combo, "open", false);
    }

    function test_comboPickReportsAndKeepsTheHostValue() {
        combo.forceActiveFocus();
        keyClick(Qt.Key_Return);
        tryCompare(combo, "open", true);
        const menu = combo.list as PopupMenu;
        menu.activated({id: "y", text: "Why"});
        compare(tc.picks, ["y"]);
        compare(combo.displayText, "Ex", "shows the host's value until it changes");
        combo.value = "y";
        compare(combo.displayText, "Why");
        tryCompare(combo, "open", false);
    }

    // The open list keeps the size its rows need (a Popup that resizes its content collapsed it to a 10 px strip).
    function test_comboListKeepsItsSizeAndShowsAllRows() {
        combo.model = [{id: "a", text: "Always"}, {id: "b", text: "On Desktop Only"}, {id: "c", text: "In Full Screen Only, a longer label"}, {id: "d", text: "Never"}];
        combo.forceActiveFocus();
        keyClick(Qt.Key_Space);
        tryCompare(combo, "open", true);
        const menu = combo.list;
        const rows = 4 * Tokens.menuItemHeight;
        verify(menu.height >= rows, "menu height " + menu.height + " holds " + rows + " of rows");
        compare(menu.height, combo.popup.height);
        compare(menu.width, combo.popup.width);
        verify(menu.width >= Tokens.menuMinWidth);
        // The last row lies inside the menu.
        const last = menu.mapToItem(menu, 0, menu.height - Tokens.menuPadding - 1);
        verify(last.y < menu.height);
        combo.popup.close();
        tryCompare(combo, "open", false);
        combo.model = [{id: "x", text: "Ex"}, {id: "y", text: "Why"}];
        combo.value = "x";
    }

    function test_progressBar() {
        fuzzyCompare(bar.visualPosition, 0.5, 1e-9);
        bar.value = 10;
        fuzzyCompare(bar.contentItem.children[0].width, bar.width, 1);
        compare(bar.height, Tokens.controlProgressHeight);
        compare(bar.Accessible.name, "Copy");
        bar.indeterminate = true;
        Appearance.reduceMotion = true;
        verify(!bar.sweeping, "no sweep with Reduce Motion");
        Appearance.reduceMotion = false;
        verify(bar.sweeping);
        Appearance.reduceMotion = false;
        bar.indeterminate = false;
        bar.value = 5;
    }

    function test_sliderKeysReportAndKeepTheHostValue() {
        slider.forceActiveFocus();
        keyClick(Qt.Key_Right);
        compare(tc.moves, 1);
        keyClick(Qt.Key_Home);
        compare(tc.moves, 2);
        compare(slider.Accessible.role, Accessible.Slider);
        compare(slider.value, 0.5);
    }

    function test_scrollBarFollowsTheView() {
        verify(scroll.visible);
        verify(scroll.size < 1);
        flick.contentY = 150;
        verify(scroll.position > 0);
        compare(scroll.Accessible.role, Accessible.ScrollBar);
        flick.contentHeight = 50;
        verify(!scroll.visible, "nothing to scroll");
        flick.contentHeight = 400;
        flick.contentY = 0;
    }

    function test_sheetConfirmErrorKeepsItOpenAndEscapeCancels() {
        sheet.open();
        verify(sheet.visible);
        sheet.setField("bad");
        keyClick(Qt.Key_Return);
        verify(sheet.visible, "an error keeps the sheet open");
        compare(sheet.errorText, "No such folder");
        sheet.setField("good");
        compare(sheet.errorText, "");
        keyClick(Qt.Key_Return);
        verify(!sheet.visible);
        sheet.open();
        keyClick(Qt.Key_Escape);
        verify(!sheet.visible);
    }
}
