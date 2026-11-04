pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import "TerminalThemeLogic.js" as Logic

// Terminal and developer apps follow the appearance (ADR-0045 OC-11; Settings > Appearance > Terminal and Developer Apps).
// With terminal.matchAppearance on, each change of the effective appearance (Settings.dark: Light, Dark, Auto at its hours),
// of the theme chosen for it, and the first reading of grassfield.json at login run
// `grassfield-terminal-theme light|dark` (packaging/bin), which applies the chosen Omarchy theme with omarchy-theme-set in an
// environment kept out of this session (no HYPRLAND_INSTANCE_SIGNATURE, Omarchy's dconf profile, the omarchy-shims first in
// PATH) and does nothing when that theme is already Omarchy's. The decision is TerminalThemeLogic.js.
//
// One run at a time, after the inputs stayed unchanged for autoAppearance.terminalSettleMs (Light, Dark, Auto clicked in a
// row make one run, for the last); a change made while a run goes on is decided when it ends. The helper runs in a scope of
// its own (systemd-run --scope): Omarchy's theme change and its thumbnail jobs are charged to that scope, never to this
// shell's CPU and memory limits (packaging/systemd/grassfield-shell.service), and a restart of the shell does not cut a theme
// change in the middle. Its status line goes to the journal ("terminal theme: ..."). In a dev session nothing runs (ADR-0019
// dev guard: the owner's Omarchy theme is not the nested session's to change); one "dev guard" line per change.
Singleton {
    id: root

    readonly property string tool: "/usr/lib/grassfield/grassfield-terminal-theme"
    // The key of the last run started (TerminalThemeLogic.key), "" for none.
    property string last: ""
    // "idle", "settling" or "running": the shell's start-up line names it (which also creates this singleton at start).
    readonly property string state: runner.running ? "running" : settle.running ? "settling" : "idle"

    readonly property var inputs: ({
            on: Settings.terminalMatchAppearance,
            loaded: Settings.loaded,
            dark: Settings.dark,
            lightTheme: Settings.terminalLightTheme,
            darkTheme: Settings.terminalDarkTheme
        })
    // What a run would be for now; any change waits for the inputs to settle.
    readonly property string wanted: Logic.key(root.inputs)
    onWantedChanged: settle.restart()

    function step(): void {
        const d = Logic.decide(Object.assign({dev: Mode.dev, running: runner.running}, root.inputs), root.last);
        root.last = d.last;
        if (d.action === "suppress") {
            console.info("dev guard: terminal theme " + d.mode + " suppressed");
        } else if (d.action === "run") {
            runner.command = ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--description=Grassfield terminal theme", "--", root.tool, d.mode];
            runner.running = true;
        }
    }

    Timer {
        id: settle
        interval: Tokens.autoAppearanceTerminalSettleMs
        onTriggered: root.step()
    }

    Process {
        id: runner
        stdout: StdioCollector {
            id: status
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => console.info("terminal theme: " + Logic.summary(status.text, exitCode))
        // qmllint enable signal-handler-parameters
        // A change made while it ran (or a helper that could not start) is decided now.
        onRunningChanged: {
            if (!running)
                settle.restart();
        }
    }
}
