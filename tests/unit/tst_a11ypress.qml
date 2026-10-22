import QtQuick
import QtTest

// R12 backlog: an assistive technology's press (Accessible.pressAction, the AT-SPI "press" action) acts only like the
// pointer and the keys would, never on a hidden or disabled control: the menu row, the Files and Preview toolbar
// buttons and the Apps chip (the shared Button: tst_buttonkeys.qml).
TestCase {
    id: tc
    name: "AccessibilityPress"
    width: 400
    height: 200
    // Shown: `visible` of a child of a hidden TestCase is false, which the guard reads.
    visible: true
    when: windowShown

    SignalSpy {
        id: spy
        signalName: "clicked"
    }

    function make(url: string, props: var): var {
        const c = Qt.createComponent(url);
        verify(c.status === Component.Ready, c.errorString());
        const o = c.createObject(tc, props);
        verify(o !== null);
        spy.target = o;
        spy.clear();
        return o;
    }

    function checkGuard(o: var, what: string): void {
        o.Accessible.pressAction();
        compare(spy.count, 1, what + ": a shown, enabled control acts on an accessibility press");
        o.enabled = false;
        o.Accessible.pressAction();
        compare(spy.count, 1, what + ": a disabled control never acts on an accessibility press");
        o.enabled = true;
        o.visible = false;
        o.Accessible.pressAction();
        compare(spy.count, 1, what + ": a hidden control never acts on an accessibility press");
        o.destroy();
    }

    function test_menuItem() {
        checkGuard(make(Qt.resolvedUrl("../../ui/Grassfield/Ui/MenuItem.qml"), {text: "Open"}), "MenuItem");
    }

    function test_filesToolButton() {
        checkGuard(make(Qt.resolvedUrl("../../apps/files/qml/ToolButton.qml"), {}), "Files ToolButton");
    }

    function test_previewToolButton() {
        checkGuard(make(Qt.resolvedUrl("../../apps/preview/qml/ToolButton.qml"), {}), "Preview ToolButton");
    }

    function test_appsChip() {
        checkGuard(make(Qt.resolvedUrl("../../shell/launchpad/AppsChip.qml"), {label: "Apps"}), "AppsChip");
    }
}
