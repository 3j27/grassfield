pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform
import qs.services
import "platform/WindowTiling.js" as WindowTiling

// Tiling step 5 (docs/specs/tiling.md TL32, ADR-0036 D36-D38; integrator review of 1c08d6b): the switches of Settings >
// Desktop & Dock > Windows gate the shell itself, on the REAL singletons (scripts/dev/test.sh: offscreen, a dev session whose
// config is under the scratch dir; no compositor: the plugin's features are set by hand). Each step writes grassfield.json
// as the Settings app does (a new file renamed over it) with ONE switch off, waits until Settings shows it, then checks:
//  - all on: a hover "enter" is not refused for the switch, groupForward goes on to groupFront, an arrangement asks for its
//    suggestion, the plugin is sent every switch on and the double-click as set;
//  - a suggestion on screen stays while a setting that is not its switch changes (the control for the next step);
//  - layouts off: TilingHover.show refuses an "enter" ("off"), not an "open" (Super+Ctrl+L, the Window menu); the plugin is
//    sent tilingLayouts false;
//  - suggestions off: the suggestion on screen ends, an arrangement asks for none; the plugin is sent tilingSuggestions false;
//  - tile groups off: groupForward says "off", groupFront (Show Tile Group) still goes on; no key is sent for it;
//  - Fill: sent as zoom without tiling-arrange, as fill with it (D36); each tiling key goes only with its own feature.
// The file that was there before is put back at the end. Prints "tiling-switches: PASS (n checks)" or the failures.
ShellRoot {
    id: root

    readonly property string file: Settings.configDir + "/grassfield.json"
    readonly property var features: ["config", "window-tiling", "tile-hover", "tiling-layouts", "tiling-groups"]
    readonly property var allOn: [["tilingEdges", "true"], ["tilingMenuBar", "true"], ["tilingOptionDrag", "true"], ["tilingMargins", "true"], ["tilingLayouts", "true"], ["tilingSuggestions", "true"]]
    property var failures: []
    property int checks: 0
    property int step: -1
    property real started: 0
    // When the plugin's features were set: TilingLink fetches the tile groups then, and a fetch that never answers (no
    // hyprctl) ends at its deadline by dropping any suggestion; the steps that show one start after it.
    property real featuresAt: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    Process {
        id: sh
    }

    function run(script: string, args: var): void {
        sh.command = ["sh", "-c", script, "sh", root.file].concat(args);
        sh.running = true;
    }

    // grassfield.json with these windows.* keys (the others at their defaults: on), renamed over the file.
    function writeWindows(windows: var): void {
        run('mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1.tmp" && mv "$1.tmp" "$1"', [JSON.stringify({version: 1, windows: windows})]);
    }

    function switches(layouts: bool, suggestions: bool, groups: bool, doubleClick: string): var {
        return {tilingLayouts: layouts, tilingSuggestions: suggestions, tilingGroups: groups, titlebarDoubleClick: doubleClick};
    }

    function shows(layouts: bool, suggestions: bool, groups: bool, doubleClick: string): bool {
        return !sh.running && Settings.windowsTilingLayouts === layouts && Settings.windowsTilingSuggestions === suggestions
            && Settings.windowsTilingGroups === groups && Settings.titlebarDoubleClick === doubleClick;
    }

    function hover(state: string): var {
        return {address: "a", state: state, light: {x: 0, y: 0, w: 14, h: 14}, tileable: true};
    }

    function pushed(key: string): string {
        const pair = Compositor.tilingPushes().find(p => p[0] === key);
        return pair ? pair[1] : "";
    }

    readonly property var suggestion: ({gen: 1, address: "a", layout: "thirds", output: "", zones: [{zone: 1, x: 0, y: 0, w: 600, h: 400}], windows: ["b"]})

    function steps(): var {
        return [{
                name: "backup",
                act: () => {
                    Capabilities.features = root.features;
                    Capabilities.pluginPresent = true;
                    root.featuresAt = Date.now();
                    root.run('if [ -e "$1" ]; then cp -p "$1" "$1.tiling-switches"; fi', []);
                },
                until: () => !sh.running
            }, {
                name: "all on",
                act: () => root.writeWindows(root.switches(true, true, true, "zoom")),
                until: () => root.shows(true, true, true, "zoom") && Date.now() - root.featuresAt > WindowTiling.suggestionWaitMs + 500,
                check: () => {
                    const why = TilingHover.show(root.hover("enter"));
                    root.check("all on: a hover enter is not refused for the switch (" + why + ")", why !== "off");
                    const group = Compositor.groupForward("a");
                    root.check("all on: groupForward goes on to groupFront (" + group + ")", group === "no group");
                    Compositor.askSuggestion("a");
                    root.check("all on: an arrangement asks for its suggestion", Compositor.suggestionAsked !== null && Compositor.suggestionAsked.address === "a");
                    root.check("all on: the plugin is sent every switch on (" + JSON.stringify(Compositor.tilingPushes()) + ")",
                        JSON.stringify(Compositor.tilingPushes()) === JSON.stringify(root.allOn));
                    root.check("all on: the double-click is sent as set (" + Compositor.titlebarDoubleClick + ")", Compositor.titlebarDoubleClick === "zoom");
                }
            }, {
                name: "control",
                act: () => {
                    TilingLink.suggestion = root.suggestion;
                    root.writeWindows(root.switches(true, true, true, "minimize"));
                },
                until: () => root.shows(true, true, true, "minimize"),
                check: () => root.check("control: a suggestion on screen stays while another setting changes", TilingLink.suggestion !== null)
            }, {
                name: "layouts off",
                act: () => root.writeWindows(root.switches(false, true, true, "minimize")),
                until: () => root.shows(false, true, true, "minimize"),
                check: () => {
                    const enter = TilingHover.show(root.hover("enter"));
                    root.check("layouts off: a hover enter is refused (" + enter + ")", enter === "off");
                    const open = TilingHover.show(root.hover("open"));
                    root.check("layouts off: an open (Super+Ctrl+L, the Window menu) is not refused for it (" + open + ")", open !== "off");
                    root.check("layouts off: the plugin is sent tilingLayouts false", root.pushed("tilingLayouts") === "false");
                    root.check("layouts off: the other switches are still sent on", root.pushed("tilingSuggestions") === "true" && root.pushed("tilingOptionDrag") === "true");
                    root.check("layouts off: the suggestion on screen stays (not its switch)", TilingLink.suggestion !== null);
                    root.check("layouts off: groupForward is not refused for it", Compositor.groupForward("a") === "no group");
                }
            }, {
                name: "suggestions off",
                act: () => {
                    Compositor.askSuggestion("a");
                    root.writeWindows(root.switches(true, false, true, "minimize"));
                },
                until: () => root.shows(true, false, true, "minimize"),
                check: () => {
                    root.check("suggestions off: the suggestion on screen ends", TilingLink.suggestion === null);
                    Compositor.askSuggestion("a");
                    root.check("suggestions off: an arrangement asks for none", Compositor.suggestionAsked === null);
                    root.check("suggestions off: the plugin is sent tilingSuggestions false", root.pushed("tilingSuggestions") === "false");
                    const why = TilingHover.show(root.hover("enter"));
                    root.check("suggestions off: a hover enter is not refused for it (" + why + ")", why !== "off");
                }
            }, {
                name: "groups off",
                act: () => root.writeWindows(root.switches(true, true, false, "minimize")),
                until: () => root.shows(true, true, false, "minimize"),
                check: () => {
                    const forward = Compositor.groupForward("a");
                    root.check("groups off: groupForward brings the window alone (" + forward + ")", forward === "off");
                    const front = Compositor.groupFront("a");
                    root.check("groups off: Show Tile Group (groupFront) still goes on (" + front + ")", front === "no group");
                    root.check("groups off: no key is sent for it (" + JSON.stringify(Compositor.tilingPushes()) + ")",
                        JSON.stringify(Compositor.tilingPushes()) === JSON.stringify(root.allOn));
                    Compositor.askSuggestion("a");
                    root.check("groups off: an arrangement still asks for its suggestion", Compositor.suggestionAsked !== null);
                }
            }, {
                name: "fill",
                act: () => root.writeWindows(root.switches(true, true, true, "fill")),
                until: () => root.shows(true, true, true, "fill"),
                check: () => {
                    root.check("fill: sent as zoom without tiling-arrange (" + Compositor.titlebarDoubleClick + ")", Compositor.titlebarDoubleClick === "zoom");
                    Capabilities.features = root.features.concat(["tiling-arrange"]);
                    root.check("fill: sent as fill with tiling-arrange (" + Compositor.titlebarDoubleClick + ")", Compositor.titlebarDoubleClick === "fill");
                    Capabilities.features = ["config", "window-tiling"];
                    root.check("features: with window-tiling alone only the drag keys go (" + JSON.stringify(Compositor.tilingPushes()) + ")",
                        JSON.stringify(Compositor.tilingPushes().map(p => p[0])) === JSON.stringify(["tilingEdges", "tilingMenuBar", "tilingOptionDrag", "tilingMargins"]));
                    Capabilities.features = ["config", "tile-hover"];
                    root.check("features: tilingLayouts goes with tile-hover", JSON.stringify(Compositor.tilingPushes()) === JSON.stringify([["tilingLayouts", "true"]]));
                    Capabilities.features = ["config", "tiling-layouts"];
                    root.check("features: tilingSuggestions goes with tiling-layouts", JSON.stringify(Compositor.tilingPushes()) === JSON.stringify([["tilingSuggestions", "true"]]));
                    Capabilities.pluginPresent = false;
                    root.check("features: nothing goes without the plugin", Compositor.tilingPushes().length === 0);
                }
            }, {
                name: "restore",
                act: () => root.run('if [ -e "$1.tiling-switches" ]; then mv "$1.tiling-switches" "$1"; else rm -f "$1"; fi', []),
                until: () => !sh.running
            }];
    }

    function begin(i: int): void {
        root.step = i;
        root.started = Date.now();
        root.steps()[i].act();
    }

    function finish(): void {
        ticker.stop();
        if (root.failures.length === 0) {
            console.log("tiling-switches: PASS (" + root.checks + " checks)");
            Qt.exit(0);
        } else {
            console.log("tiling-switches: FAIL: " + root.failures.join("; "));
            Qt.exit(1);
        }
    }

    // Each step acts, then waits until Settings shows its file (at most 8 s: the store watches the file and also polls it),
    // then checks. A step that times out is a failure; the next steps still run, the restore last.
    function tick(): void {
        if (root.step < 0) {
            root.begin(0);
            return;
        }
        const s = root.steps()[root.step];
        if (!s.until()) {
            if (Date.now() - root.started < 8000)
                return;
            root.check(s.name + ": timed out waiting for the file and Settings (8 s)", false);
        } else if (s.check) {
            s.check();
        }
        if (root.step + 1 < root.steps().length)
            root.begin(root.step + 1);
        else
            root.finish();
    }

    Timer {
        id: ticker
        interval: 100
        repeat: true
        running: true
        onTriggered: root.tick()
    }
}
