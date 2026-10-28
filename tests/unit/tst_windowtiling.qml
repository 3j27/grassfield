import QtQuick
import QtTest
import "../../shell/platform/WindowTiling.js" as WindowTiling

// The tiling popover's link to the compositor (shell/platform/WindowTiling.js, docs/specs/tiling.md TL22-TL26): the plugin's
// tile-hover event, where the popover opens, the outputs a window can move to.
TestCase {
    name: "WindowTiling"

    function test_parseHoverReadsEnterOpenAndLeave() {
        const enter = WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"55AB","state":"enter","x":120.5,"y":40,"w":14,"h":14,"tileable":true}');
        compare(enter.address, "55ab");
        compare(enter.state, "enter");
        compare(JSON.stringify(enter.light), JSON.stringify({x: 120.5, y: 40, w: 14, h: 14}));
        verify(enter.tileable);
        const open = WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"0x1","state":"open","x":0,"y":0,"w":32,"h":32,"tileable":false}');
        compare(open.state, "open");
        compare(open.address, "1");
        verify(!open.tileable);
        const leave = WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"55ab","state":"leave"}');
        compare(leave.state, "leave");
        compare(leave.light, null);
        // tileable is true only when the plugin says so.
        verify(!WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"1","state":"enter","x":0,"y":0,"w":1,"h":1,"tileable":"yes"}').tileable);
    }

    function test_parseHoverRefusesAnythingElse() {
        const bad = [
            "", "not json", "null", "[]",
            '{"v":"gfc/2","type":"tile-hover","address":"1","state":"leave"}',
            '{"v":"gfc/1","type":"tiling","gen":3}',
            '{"v":"gfc/1","type":"minimize-request","address":"1"}',
            '{"v":"gfc/1","type":"tile-hover","address":"xyz","state":"leave"}',
            '{"v":"gfc/1","type":"tile-hover","address":"12345678901234567","state":"leave"}',
            '{"v":"gfc/1","type":"tile-hover","address":7,"state":"leave"}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"hover"}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"enter"}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"enter","x":0,"y":0,"w":0,"h":14}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"open","x":"0","y":0,"w":14,"h":14}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"open","x":0,"y":0,"w":-1,"h":14}'
        ];
        for (const text of bad)
            compare(WindowTiling.parseHover(text), null, text);
    }

    readonly property var screens: [
        {name: "eDP-1", model: "Panel", x: 0, y: 0, width: 1440, height: 900},
        {name: "DP-1", model: " LG UltraFine ", x: 1440, y: -200, width: 2560, height: 1440},
        {name: "HDMI-A-1", model: "", x: -1920, y: 0, width: 1920, height: 1080}
    ]

    function test_popoverAnchorIsInTheScreenOfTheLightsMiddle() {
        const a = WindowTiling.popoverAnchor({x: 1500, y: -150, w: 14, h: 14}, screens);
        compare(a.screen, "DP-1");
        compare(a.x, 67);
        compare(a.y, 64);
        compare(a.flipY, 50);
        compare(JSON.stringify(a.light), JSON.stringify({x: 60, y: 50, w: 14, h: 14}));
        // A light straddling two screens belongs to the one under its middle.
        compare(WindowTiling.popoverAnchor({x: 1436, y: 10, w: 14, h: 14}, screens).screen, "DP-1");
        compare(WindowTiling.popoverAnchor({x: 1420, y: 10, w: 14, h: 14}, screens).screen, "eDP-1");
        compare(WindowTiling.popoverAnchor({x: -100, y: 500, w: 14, h: 14}, screens).screen, "HDMI-A-1");
        compare(WindowTiling.popoverAnchor({x: 100, y: 5000, w: 14, h: 14}, screens), null);
        compare(WindowTiling.popoverAnchor(null, screens), null);
        compare(WindowTiling.popoverAnchor({x: 0, y: 0, w: 14, h: 14}, null), null);
    }

    function test_otherOutputsAreTheOthersWithTheirNames() {
        const others = WindowTiling.otherOutputs(screens, "DP-1");
        compare(others.map(o => o.name).join(","), "eDP-1,HDMI-A-1");
        verify(others[0].builtIn, "an eDP connector is the built-in panel");
        verify(!others[1].builtIn);
        compare(WindowTiling.otherOutputs(screens, "eDP-1")[0].model, "LG UltraFine");
        for (const name of ["LVDS-1", "DSI-1"])
            verify(WindowTiling.otherOutputs([{name: name, model: ""}], "")[0].builtIn, name);
        verify(!WindowTiling.otherOutputs([{name: "XeDP-1", model: ""}], "")[0].builtIn);
        compare(WindowTiling.otherOutputs([screens[0]], "eDP-1").length, 0, "one output: no Move to row");
        compare(WindowTiling.otherOutputs(null, "").length, 0);
    }

    function test_nextOutputGoesByPositionAndWraps() {
        compare(WindowTiling.nextOutput(screens, "eDP-1", "right"), "DP-1");
        compare(WindowTiling.nextOutput(screens, "eDP-1", "left"), "HDMI-A-1");
        compare(WindowTiling.nextOutput(screens, "DP-1", "right"), "HDMI-A-1", "wraps");
        compare(WindowTiling.nextOutput(screens, "HDMI-A-1", "left"), "DP-1", "wraps");
        compare(WindowTiling.nextOutput([screens[0]], "eDP-1", "right"), "");
        compare(WindowTiling.nextOutput(screens, "DP-9", "right"), "");
        compare(WindowTiling.nextOutput(screens, "eDP-1", "up"), "");
        // Stacked outputs (same x): top to bottom.
        const stacked = [{name: "B", x: 0, y: 1080}, {name: "A", x: 0, y: 0}];
        compare(WindowTiling.nextOutput(stacked, "A", "right"), "B");
    }
}
