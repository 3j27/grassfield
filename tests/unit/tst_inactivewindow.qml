import QtQuick
import QtTest
import Grassfield.Ui

// A window that is not key (ADR-0039 step 17; audit §3.13, measured on macOS 27): the toolbar's title and a ToolButton's glyph
// dim to the text colour at Appearance.inactiveTextOpacity, and come back when the window is key again. While a shell menu or
// the Control Center holds the keyboard the window keeps its key look (Appearance.heldKeyWindow, set by the app from the
// shell's key-window file: apps/keywindow.h, tests/unit/activity/qml/tst_keywindow.cpp); only another window taking the focus
// makes it inactive. Settings' sidebar selection is tst_settingsmain (it needs its window), the Store's tst_storefinish.
TestCase {
    id: tc

    name: "InactiveWindow"
    width: 400
    height: 120
    visible: true
    when: windowShown

    UnifiedToolbar {
        id: toolbar
        width: 400
        title: "Desktop & Dock"
        showControls: false
    }

    ToolButton {
        id: tool
        y: 70
        iconName: "chevron-right"
        accessibleName: "Forward"
    }

    WindowControls {
        id: lights
        x: 100
        y: 70
        window: tool.Window.window
    }

    Component {
        id: otherWindow
        Window {
            width: 60
            height: 60
            visible: true
        }
    }

    // Two colours alike to the 8-bit step (an alpha set as 0.32 reads back as 82/255).
    function near(a, b) {
        const ca = Qt.color(a), cb = Qt.color(b);
        return Math.abs(ca.r - cb.r) < 0.005 && Math.abs(ca.g - cb.g) < 0.005 && Math.abs(ca.b - cb.b) < 0.005 && Math.abs(ca.a - cb.a) < 0.005;
    }

    function titleOf(bar) {
        const stack = [bar];
        while (stack.length > 0) {
            const it = stack.shift();
            if (String(it).indexOf("QQuickText") === 0 && it.text === "Desktop & Dock")
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_theTokens() {
        compare(Tokens.windowInactiveTextOpacityLight, 0.28);
        compare(Tokens.windowInactiveTextOpacityDark, 0.32);
        compare(Tokens.windowInactiveSelectionOpacityLight, 0.045);
        Appearance.dark = false;
        compare(Appearance.inactiveTextOpacity, Tokens.windowInactiveTextOpacityLight);
        compare(Appearance.inactiveSelectionOpacity, Tokens.windowInactiveSelectionOpacityLight);
        Appearance.dark = true;
        compare(Appearance.inactiveTextOpacity, Tokens.windowInactiveTextOpacityDark);
    }

    function test_theToolbarDimsWhileTheWindowIsNotKey() {
        const title = titleOf(toolbar);
        verify(title !== null);
        tryVerify(() => tool.Window.active, 2000, "the test window starts key");
        verify(Qt.colorEqual(title.color, Appearance.colors.text), "key: the title in the text colour");
        verify(Qt.colorEqual(tool.foreground, Appearance.colors.text), "key: the glyph in the text colour");
        const other = createTemporaryObject(otherWindow, null);
        other.requestActivate();
        tryVerify(() => !tool.Window.active, 2000, "another window is key");
        const dim = Appearance.withAlpha(Appearance.colors.text, Appearance.inactiveTextOpacity);
        verify(near(title.color, dim), "not key: the title dims: " + title.color);
        verify(near(tool.foreground, dim), "not key: the glyph dims: " + tool.foreground);
        other.close();
        tool.Window.window.requestActivate();
        tryVerify(() => tool.Window.active, 2000);
        verify(Qt.colorEqual(title.color, Appearance.colors.text), "key again");
    }

    function cleanup() {
        Appearance.heldKeyWindow = null;
    }

    function test_aShellMenuLeavesTheWindowKey() {
        const title = titleOf(toolbar);
        const win = tool.Window.window;
        tryVerify(() => tool.Window.active, 2000, "the test window starts key");
        verify(lights.active, "the lights in colour");
        const other = createTemporaryObject(otherWindow, null);
        other.requestActivate();
        tryVerify(() => !tool.Window.active, 2000, "the window lost its activation");
        verify(!lights.active && !Appearance.looksKey(win, false));
        // The shell names this window's client while its menu holds the keyboard: the app holds the window key.
        Appearance.heldKeyWindow = win;
        verify(Appearance.looksKey(win, false), "held: key");
        verify(!Appearance.looksKey(other, false), "only the held window");
        verify(!Appearance.looksKey(null, false));
        verify(Qt.colorEqual(title.color, Appearance.colors.text), "the title stays in the text colour");
        verify(Qt.colorEqual(tool.foreground, Appearance.colors.text), "the glyph too");
        verify(lights.active, "and the lights");
        // Another window took the focus: the app no longer holds it.
        Appearance.heldKeyWindow = null;
        const dim = Appearance.withAlpha(Appearance.colors.text, Appearance.inactiveTextOpacity);
        verify(near(title.color, dim) && near(tool.foreground, dim) && !lights.active, "inactive");
        other.close();
        win.requestActivate();
        tryVerify(() => tool.Window.active, 2000);
    }
}
