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
        // On its bound the latch still waits for the wallpapers (review of 3a5e1b80), not for the bars.
        let w = Logic.withExpected(Logic.withExpected({}, "wallpaper:A"), "dock");
        verify(Logic.wallpaperPending(w));
        w = Logic.withReady(w, "wallpaper:A");
        verify(!Logic.wallpaperPending(w), "only the Dock is late: the timeout reveals");
        // A surface that went first is no longer waited for.
        verify(Logic.allReady(Logic.without(w, "dock")));
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
        verify(/interval: Tokens\.sessionRevealTimeoutMs\s*onTriggered: \{\s*root\.timedOut = true;\s*root\.check\(\);/.test(e));
        verify(/readonly property bool settingsFinal: Settings\.loaded \|\| root\.settingsWaited/.test(e));
        const w = source("shell/desktop/Wallpaper.qml");
        verify(/win\.entranceKey = "wallpaper:"/.test(w) && /Entrance\.begin\(\);/.test(w));
        const bar = source("shell/menubar/MenuBar.qml");
        verify(/win\.entranceKey = "menubar:" \+ win\.screen\.name;/.test(bar));
        // ID-6: the auto-hide starts where it rests, once the settings are final.
        verify(/function settleBar\(\): void \{\s*win\.hideMachine = AutoHide\.initial\(win\.autoHides\);\s*Entrance\.ready\(win\.entranceKey\);/.test(bar));
        // The band stays opaque when dimmed under Reduce Transparency (ADR-0039 step 25), and fades in all the same.
        compare((bar.match(/opacity: (?:\(Appearance\.reduceTransparency \? 1 : win\.dimOpacity\)|win\.dimOpacity) \* win\.entrance/g) || []).length, 2, "the band and the content fade in");
        verify(/armed: win\.entered/.test(bar), "P5 counts the entrance");
        const dock = source("shell/dock/Dock.qml");
        verify(/Entrance\.expect\("dock"\);/.test(dock));
        // The Dock is ready once settled and placed, from its own window (review of 3a5e1b80).
        verify(/readonly property bool entranceReady: root\.settled && \(placed \|\| placedGivenUp\)/.test(dock));
        verify(/readonly property bool revealWanted: root\.settled && \(placed \|\| placedGivenUp\) && Entrance\.revealed/.test(dock));
        verify(/if \(entranceReady && isDockScreen\)\s*Entrance\.ready\("dock"\);/.test(dock));
        // The bar's blur and input wait for the entrance; its auto-hide is set again until and at it.
        verify(/BackgroundEffect\.blurRegion: win\.entered && /.test(bar));
        verify(/height: win\.entered \? BarHide\.inputHeight\(/.test(bar));
        verify(/onAutoHidesChanged: \{\s*if \(!win\.entered && win\.barFinal\)\s*win\.hideMachine = AutoHide\.initial\(win\.autoHides\);/.test(bar));
        // On its bound the latch waits for the wallpapers' own bound.
        verify(/else if \(root\.timedOut && !Logic\.wallpaperPending\(root\.expected\)\)/.test(e));
        // And a hard bound past both (re-check of 89390113: a leaked key never holds the entrance for good).
        verify(/interval: Tokens\.sessionRevealTimeoutMs \+ Tokens\.wallpaperFirstShowTimeoutMs\s*onTriggered: root\.reveal\("timeout"\)/.test(e));
        // Each surface takes its key once, at creation, and forgets that same key.
        for (const t of [w, bar]) {
            verify(/Entrance\.expect\(win\.entranceKey\);/.test(t) && /Entrance\.forget\(win\.entranceKey\);/.test(t) && /Entrance\.ready\(win\.entranceKey\);/.test(t));
            verify(!/Entrance\.(ready|forget|expect)\("/.test(t), "no key rebuilt from the screen");
        }
        const icons = source("shell/desktop/IconsView.qml");
        verify(/opacity: entrance/.test(icons) && /Entrance\.expect\(root\.entranceKey\);/.test(icons) && /Entrance\.ready\(root\.entranceKey\);/.test(icons));
        verify(/enabled: !Entrance\.revealed/.test(icons), "no pointer input on the invisible icons");
        // One fade length for the three, capped by Reduce Motion.
        for (const t of [bar, dock, icons])
            verify(/duration: Appearance\.duration\(Tokens\.sessionRevealMs\)/.test(t));
    }
}
