import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/services/EntranceLogic.js" as Logic

// ADR-0040 step 6 (ID-20, ID-5, ID-6): the session's entrance. The latch's rule is pure (EntranceLogic.js); the surfaces need
// Quickshell, so their wiring is read from the sources. The nested part is tests/visual/appear-once.sh.
TestCase {
    name: "Entrance"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_theLatchWaitsForEverySurface() {
        let e = {};
        verify(!Logic.allReady(e), "nothing expected: only the timeout enters");
        for (const k of ["wallpaper:A", "menubar:A", "dock", "icons:A"])
            e = Logic.withExpected(e, k);
        compare(Logic.pending(e), ["dock", "icons:A", "menubar:A", "wallpaper:A"]);
        e = Logic.withReady(e, "wallpaper:A");
        e = Logic.withReady(e, "menubar:A");
        e = Logic.withReady(e, "icons:A");
        verify(!Logic.allReady(e));
        compare(Logic.pending(e), ["dock"]);
        e = Logic.withReady(e, "dock");
        verify(Logic.allReady(e));
        // Expecting again a key that is ready does not take it back.
        verify(Logic.allReady(Logic.withExpected(e, "dock")));
        // A key ready before it was expected counts.
        verify(Logic.allReady(Logic.withExpected(Logic.withReady({}, "x"), "x")));
        compare(Logic.pending(null), []);
        verify(!Logic.allReady(null));
    }

    function test_theTokens() {
        compare(Tokens.sessionSettingsWaitMs, 500);
        compare(Tokens.sessionRevealTimeoutMs, 1500);
        compare(Tokens.sessionRevealMs, 250);
        verify(Tokens.sessionSettingsWaitMs < Tokens.sessionRevealTimeoutMs, "the settings are waited for inside the entrance's bound");
        verify(Tokens.wallpaperFirstShowTimeoutMs <= Tokens.sessionRevealTimeoutMs, "the wallpaper's first frame comes within the bound");
    }

    function test_theSurfacesWaitAndFadeTogether() {
        const e = source("shell/services/Entrance.qml");
        verify(/interval: Tokens\.sessionRevealTimeoutMs\s*onTriggered: root\.reveal\("timeout"\)/.test(e));
        verify(/readonly property bool settingsFinal: Settings\.loaded \|\| root\.settingsWaited/.test(e));
        const w = source("shell/desktop/Wallpaper.qml");
        verify(/Entrance\.expect\("wallpaper:"/.test(w) && /Entrance\.ready\("wallpaper:"/.test(w) && /Entrance\.begin\(\);/.test(w));
        const bar = source("shell/menubar/MenuBar.qml");
        verify(/Entrance\.expect\("menubar:" \+ win\.screen\.name\);/.test(bar));
        // ID-6: the auto-hide starts where it rests, once the settings are final.
        verify(/function settleBar\(\): void \{\s*win\.hideMachine = AutoHide\.initial\(win\.autoHides\);\s*Entrance\.ready\("menubar:" \+ win\.screen\.name\);/.test(bar));
        compare((bar.match(/opacity: win\.dimOpacity \* win\.entrance/g) || []).length, 2, "the band and the content fade in");
        verify(/armed: win\.entered/.test(bar), "P5 counts the entrance");
        const dock = source("shell/dock/Dock.qml");
        verify(/Entrance\.expect\("dock"\);/.test(dock) && /settled = true;\s*Entrance\.ready\("dock"\);/.test(dock));
        verify(/readonly property bool revealWanted: root\.settled && \(placed \|\| placedGivenUp\) && Entrance\.revealed/.test(dock));
        const icons = source("shell/desktop/IconsView.qml");
        verify(/opacity: entrance/.test(icons) && /Entrance\.expect\(root\.entranceKey\);/.test(icons) && /Entrance\.ready\(root\.entranceKey\);/.test(icons));
        // One fade length for the three, capped by Reduce Motion.
        for (const t of [bar, dock, icons])
            verify(/duration: Appearance\.duration\(Tokens\.sessionRevealMs\)/.test(t));
    }
}
