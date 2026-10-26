import QtQuick
import QtTest
import Grassfield.Ui

// Menu shortcut labels by device (owner decision 2026-10-26, ADR-0024 C-8; MenuShortcut.js): the text on a PC, the macOS symbols on
// a Mac, the device read from the firmware vendor and the input devices, and the setting that forces either.
TestCase {
    id: testCase

    name: "MenuShortcut"
    width: 300
    height: 200
    // Shown, so that the menu's items are visible (a TestCase item starts hidden).
    visible: true
    when: windowShown

    PopupMenu {
        id: menu
        model: [{id: "a", text: "Lock Screen", shortcut: "Super+L"}, {id: "b", text: "New Folder", shortcut: "Ctrl+Shift+N"}]
    }

    readonly property string appleKeyboard: "I: Bus=0003 Vendor=05ac Product=024f Version=0111\nN: Name=\"Apple Inc. Magic Keyboard\"\nH: Handlers=sysrq kbd leds event3\nB: EV=120013\n"
    readonly property string appleBluetoothKeyboard: "I: Bus=0005 Vendor=004c Product=0267 Version=0001\nN: Name=\"Magic Keyboard\"\nH: Handlers=sysrq kbd leds event7\n"
    readonly property string appleTrackpadOnly: "I: Bus=0003 Vendor=05ac Product=0265 Version=0110\nN: Name=\"Apple Inc. Magic Trackpad\"\nH: Handlers=mouse2 event5\n"
    readonly property string pcKeyboard: "I: Bus=0011 Vendor=0001 Product=0001 Version=ab41\nN: Name=\"AT Translated Set 2 keyboard\"\nH: Handlers=sysrq kbd leds event0\n"

    function cleanup() {
        Appearance.shortcutStyle = "pc";
    }

    function test_pcKeepsTheText() {
        compare(MenuShortcut.label("Ctrl+Shift+N", "pc"), "Ctrl+Shift+N");
        compare(MenuShortcut.label("Ctrl+Maj+N", "pc"), "Ctrl+Maj+N");
        compare(MenuShortcut.label("", "mac"), "");
    }

    function test_macSymbolsInTheMacOrder() {
        compare(MenuShortcut.label("Super+L", "mac"), "⌘L");
        compare(MenuShortcut.label("Shift+Super+Q", "mac"), "⇧⌘Q");
        compare(MenuShortcut.label("Super+Ctrl+F", "mac"), "⌃⌘F");
        compare(MenuShortcut.label("Ctrl+Alt+Esc", "mac"), "⌃⌥⎋");
        compare(MenuShortcut.label("Ctrl+,", "mac"), "⌃,");
        compare(MenuShortcut.label("Ctrl++", "mac"), "⌃+");
        compare(MenuShortcut.label("Super+Ctrl+Left", "mac"), "⌃⌘←");
        compare(MenuShortcut.label("Ctrl+Backspace", "mac"), "⌃⌫");
        compare(MenuShortcut.label("Return", "mac"), "↩");
        compare(MenuShortcut.label("F2", "mac"), "F2");
        compare(MenuShortcut.label("Space", "mac"), "Space");
        compare(MenuShortcut.label("Ctrl+o", "mac"), "⌃O");
    }

    function test_translatedNames() {
        compare(MenuShortcut.label("Ctrl+Maj+N", "mac"), "⌃⇧N");
        compare(MenuShortcut.label("Super+Ctrl+Gauche", "mac"), "⌃⌘←");
        compare(MenuShortcut.label("Ctrl+Retour arrière", "mac"), "⌃⌫");
    }

    function test_unknownTextIsShownAsWritten() {
        compare(MenuShortcut.label("Hyper+X", "mac"), "Hyper+X");
        compare(MenuShortcut.label("Click", "mac"), "Click");
    }

    function test_macDevice() {
        verify(MenuShortcut.macDevice("Apple Inc.\n", ""));
        verify(MenuShortcut.macDevice("LENOVO", testCase.pcKeyboard + "\n" + testCase.appleKeyboard));
        verify(MenuShortcut.macDevice("", testCase.appleBluetoothKeyboard));
        verify(!MenuShortcut.macDevice("LENOVO", testCase.pcKeyboard + "\n" + testCase.appleTrackpadOnly));
        verify(!MenuShortcut.macDevice("", ""));
        verify(!MenuShortcut.macDevice(undefined, undefined));
    }

    function test_style() {
        compare(MenuShortcut.style("automatic", true), "mac");
        compare(MenuShortcut.style("automatic", false), "pc");
        compare(MenuShortcut.style("mac", false), "mac");
        compare(MenuShortcut.style("pc", true), "pc");
        compare(MenuShortcut.style("bogus", true), "mac");
        compare(MenuShortcut.style(undefined, false), "pc");
    }

    function test_menuShowsTheStyle() {
        const texts = [];
        const walk = item => {
            for (let i = 0; i < item.children.length; i++) {
                const c = item.children[i];
                if (String(c).indexOf("QQuickText") === 0 && c.visible)
                    texts.push(c.text);
                walk(c);
            }
        };
        walk(menu);
        verify(texts.indexOf("Super+L") >= 0, texts.join(" | "));
        Appearance.shortcutStyle = "mac";
        texts.length = 0;
        walk(menu);
        verify(texts.indexOf("⌘L") >= 0, texts.join(" | "));
        verify(texts.indexOf("⌃⇧N") >= 0, texts.join(" | "));
    }
}
