import QtQuick
import QtTest
import Grassfield.Ui

// ADR-0040 step 7, the exit cover (ID-10): its tokens hold together, its ground is the compositor's background colour (ID-2:
// what shows once the shell itself has stopped is the same colour), the compositor adds no fade of its own and no blur, and its
// IPC is the one packaging/bin/grassfield-session-end calls. The cover (shell/overlay/ExitCover.qml) needs Quickshell, so its
// contract is read from the sources here; the helper's side runs against fakes in tests/shell/session_end.sh.
TestCase {
    name: "SessionExit"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function cleanup() {
        Appearance.reduceMotion = false;
    }

    function test_theGroundIsTheCompositorsBackground() {
        const m = /^\s*background_color = "rgba\(([0-9a-fA-F]{6})ff\)",/m.exec(source("config/hypr/grassfield/looknfeel.lua"));
        verify(m !== null, "looknfeel.lua sets an opaque background_color");
        compare(("#" + m[1]).toUpperCase(), Tokens.sessionGround.toUpperCase());
    }

    function test_theTimesHoldTogether() {
        compare(Tokens.sessionExitCountdownSeconds, 60, "macOS's 60 seconds (ID-21)");
        verify(Tokens.sessionExitFadeMs <= Tokens.sessionExitWaitMs, "the helper waits for the whole fade");
        verify(Tokens.sessionExitCoverHoldMs > 10 * Tokens.sessionExitWaitMs, "a slow but real exit is never uncovered");
        Appearance.reduceMotion = true;
        verify(Appearance.duration(Tokens.sessionExitFadeMs) <= Tokens.motionReducedMax, "Reduce Motion caps the fade (P-7)");
    }

    function test_theCoverIsTheShellsAlone() {
        const cover = source("shell/overlay/ExitCover.qml");
        const ns = /WlrLayershell\.namespace: "([a-z-]+)"/.exec(cover);
        verify(ns !== null);
        compare(ns[1], "grassfield-exit-cover");
        verify(/WlrLayershell\.layer: WlrLayer\.Overlay/.test(cover), "above the menu bar, the Dock and the popups");
        // The ground of what is on screen (ADR-0040 step 3), the compositor's background colour too (Compositor.qml pushes it);
        // the static session.ground until a wallpaper reports one.
        // The cover fades to the colour Hyprland accepted (review of 4457edc1, m2): what shows once the shell has stopped.
        verify(/color: Ground\.accepted/.test(cover));
        const ground = source("shell/services/Ground.qml");
        verify(/property string accepted: Tokens\.sessionGround/.test(ground), "the config's static default until Hyprland accepted another");
        verify(/readonly property string current: WallpaperConfig\.groundFor\(root\.grounds, root\.firstScreen, Tokens\.sessionGround\)/.test(ground));
        const comp = source("shell/platform/Compositor.qml");
        verify(/readonly property string ground: Ground\.current/.test(comp) && /Minimized\.groundCall\(root\.ground\)/.test(comp), "the compositor gets the shown ground");
        verify(/if \(answer === "ok"\)\s*Ground\.accepted = sock\.value;/.test(comp), "only an accepted ground is the cover's");
        verify(/if \(!root\.groundKnown \|\| root\.groundRejected/.test(comp), "nothing pushed before the first screen reported (no flash at a restart)");
        verify(/duration: root\.fadeMs/.test(cover) && /readonly property int fadeMs: Appearance\.duration\(Tokens\.sessionExitFadeMs\)/.test(cover));
        // The compositor neither fades it (one owner of motion, ID-4) nor blurs it (it is opaque).
        const lua = source("config/hypr/grassfield/windows.lua");
        const noAnim = (lua.match(/^hl\.layer_rule\(\{.*no_anim = true.*\}\)$/gm) || []).map(r => /namespace = "([^"]+)"/.exec(r)[1]);
        verify(noAnim.some(p => new RegExp(p).test(ns[1])), "a no_anim layer rule matches " + ns[1]);
        const blur = (lua.match(/^hl\.layer_rule\(\{.*blur = true.*\}\)$/gm) || []).map(r => /namespace = "([^"]+)"/.exec(r)[1]);
        verify(blur.length > 0 && !blur.some(p => new RegExp(p).test(ns[1])), "no blur rule matches " + ns[1]);
    }

    function test_theHelperCallsWhatTheShellServes() {
        const cover = source("shell/overlay/ExitCover.qml");
        verify(/target: "session"/.test(cover));
        for (const f of ["cover", "lift", "state"])
            verify(new RegExp("function " + f + "\\(\\): string \\{").test(cover), f);
        verify(/return Math\.min\(root\.fadeMs, Tokens\.sessionExitWaitMs\);/.test(cover), "the answer never asks for more than the bound");
        verify(/function cover\(\): int \{\s*if \(SessionState\.refuses\("exit cover"\)\)\s*return 0;/.test(cover), "refused while locked: nothing to wait for");
        verify(/interval: Tokens\.sessionExitCoverHoldMs/.test(cover), "the cover lifts by itself");
        verify(/function state\(\): string \{\s*if \(!VisualFixtures\.dev\)\s*return "";/.test(cover), "state is a dev hook");
        const helper = source("packaging/bin/grassfield-session-end");
        verify(/^COVER = "qs ipc -p \/usr\/share\/grassfield\/shell call session cover"  # i18n-ignore \(a command line\)$/m.test(helper));
        verify(/^LIFT = "qs ipc -p \/usr\/share\/grassfield\/shell call session lift"  # i18n-ignore \(a command line\)$/m.test(helper));
        verify(/shell_call\(COVER, EXIT_WAIT\)/.test(helper) && /shell_call\(LIFT, EXIT_WAIT\)/.test(helper));
        verify(/^\s+ExitCover \{\}$/m.test(source("shell/shell.qml")), "the shell builds the cover");
        verify(/^ExitCover 1\.0 ExitCover\.qml$/m.test(source("shell/overlay/qmldir")));
    }
}
