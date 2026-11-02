import QtQuick
import QtTest
import Grassfield.Ui

// Motion roles (ADR-0039 Q6 and step 20; audit §3.16): panels and sheets on Apple's default spring as a 650-ms stand-in, one
// curve per role (move, enter, exit) that the compositor's windows and layers share (looknfeel.lua's gfStandard, gfDecelerate,
// gfAccelerate: read here and held equal to the tokens), and the free surfaces moved off Qt's ease types.
TestCase {
    name: "MotionRoles"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    // The four control-point numbers of a hl.curve in looknfeel.lua.
    function luaCurve(lua, name) {
        const m = new RegExp('hl\\.curve\\("' + name + '",\\s*\\{[^}]*points\\s*=\\s*\\{\\s*\\{\\s*([-0-9.]+),\\s*([-0-9.]+)\\s*\\},\\s*\\{\\s*([-0-9.]+),\\s*([-0-9.]+)\\s*\\}').exec(lua);
        verify(m !== null, name + " in looknfeel.lua");
        return [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])];
    }

    function test_thePanelMotion() {
        compare(Tokens.motionPanel, 650, "Apple's default spring as a fixed-duration stand-in");
        compare(Tokens.motionCurvePanel.slice(0, 4), [0.24, 0.24, 0.15, 1.04]);
        compare(Appearance.curvePanel, Tokens.motionCurvePanel);
    }

    function test_theCompositorSharesTheCurves_data() {
        return [
            {tag: "move", lua: "gfStandard", curve: Tokens.motionCurveStandard},
            {tag: "enter", lua: "gfDecelerate", curve: Tokens.motionCurveEnter},
            {tag: "exit", lua: "gfAccelerate", curve: Tokens.motionCurveExit}
        ];
    }

    function test_theCompositorSharesTheCurves(data) {
        const lua = source("config/hypr/grassfield/looknfeel.lua");
        compare(luaCurve(lua, data.lua), data.curve.slice(0, 4), data.tag + ": the shell's and the compositor's curve are one");
    }

    function test_theSurfacesTakeTheRoles_data() {
        return [
            {tag: "the Notification Center slides as a panel", path: "shell/notifications/NotificationCenter.qml", has: ["Tokens.motionPanel", "Appearance.curvePanel"]},
            {tag: "a banner slides in as a panel", path: "shell/notifications/Banner.qml", has: ["Tokens.motionPanel", "Appearance.curvePanel"]},
            {tag: "the stack fan arrives", path: "shell/overlay/StackPopup.qml", has: ["Appearance.curveEnter"]},
            {tag: "the switcher arrives", path: "shell/switcher/SwitcherWindow.qml", has: ["Appearance.curveEnter"]},
            {tag: "the Overview's tiles move", path: "shell/overview/OverviewWindow.qml", has: ["Appearance.curve"]},
            {tag: "Search resizes", path: "shell/search/SearchPanel.qml", has: ["Appearance.curve"]}
        ];
    }

    function test_theSurfacesTakeTheRoles(data) {
        const text = source(data.path);
        for (const needle of data.has)
            verify(text.indexOf(needle) >= 0, data.tag + ": " + needle);
        verify(!/Easing\.(OutQuad|OutCubic|InOutQuad|InQuad)\b/.test(text), data.tag + ": no Qt ease type left");
    }
}
