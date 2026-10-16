import QtQuick
import QtTest
import Grassfield.Ui

// The PopupMenu component driven by real key events (navigation model is in tst_menunav).
TestCase {
    id: testCase
    name: "PopupMenu"
    width: 400
    height: 400
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

    function test_sizing() {
        const m = makeMenu();
        verify(m.width >= Tokens.menuMinWidth);
        verify(m.height > 0);
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
        keyClick(Qt.Key_Right);
        compare(m.openIndex, 4);
        wait(100);
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        compare(activatedSpy.count, 1);
        compare(activatedSpy.signalArguments[0][0].id, "d2");
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
}
