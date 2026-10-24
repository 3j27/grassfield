pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.services
import "Minimized.js" as Minimized
import "StagesState.js" as StagesState

// The shell's side of the compositor plugin's Stages (docs/specs/stages.md "Shell contract"): capability, the user's
// setting, the plugin's state events and the `stages` verb. Only this file (with Compositor and Capabilities) talks to
// the compositor; the strip surfaces (shell/stages) read it. Event-driven; without the plugin or without `stages-available`
// nothing here is ever active and nothing is sent.
Singleton {
    id: root

    // The plugin offers Stages (the Quick Settings toggle and the Settings entry exist only then).
    readonly property bool available: Capabilities.has("stages-available")
    // The user's setting (windows.stages, off by default).
    readonly property bool enabled: Settings.windowsStages
    // The plugin's flag is on (`stages` capability): the strips may be mapped and `op:on` sent.
    readonly property bool flagOn: Capabilities.has("stages")
    readonly property bool active: available && enabled && flagOn

    // Last state (StagesState.parse of `hyprctl grassfield-stages`, or of an older plugin's full event) or null; cleared
    // when Stages ends.
    property var state: null
    // A notice came while the state was being fetched: fetch again when that one ends (the latest state wins).
    property bool fetchAgain: false
    readonly property bool on: state !== null && state.on
    // Last refusal or end reason of an event ("" none): invalid | disabled | no-strip | unknown | unavailable | interrupted.
    property string reason: ""

    // A refusal or interruption that asks the strip to send `op:on` again (`no-strip`, `interrupted`).
    signal resendNeeded(string reason)
    // The capabilities say Stages is on (also after each reload of the plugin): send `op:on` again.
    signal resumed

    function monitorState(name: string): var {
        return state && state.monitors[name] ? state.monitors[name] : null;
    }

    // Sends an operation through Compositor.stages (the plugin validates every field); false (nothing sent) when Stages is not
    // active or the request is not one of its operations.
    // The state of the latest notice (the event carries none: Hyprland cuts socket2 events at 1024 bytes).
    function fetchState(): void {
        if (stateFetch.running)
            root.fetchAgain = true;
        else
            stateFetch.running = true;
    }

    function applyFetched(text: string): void {
        const parsed = StagesState.parse(text);
        // Only a complete state, never an older generation than the one shown, and only while Stages may run.
        if (!parsed || !parsed.complete || !root.active)
            return;
        if (root.state && parsed.gen >= 0 && root.state.gen > parsed.gen)
            return;
        root.state = parsed;
    }

    function send(request: var): bool {
        if (!root.active)
            return false;
        return Compositor.stages(request);
    }

    // Window class of a Hyprland window address (lower-case hex, no 0x), "" when unknown. `revision` makes bindings
    // re-evaluate (Compositor.topologyRevision).
    function appIdOf(address: string, revision: int): string {
        const wanted = Minimized.normalizeAddress(address);
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            const top = all[i];
            if (Minimized.normalizeAddress(top.address) !== wanted)
                continue;
            if (top.wayland && top.wayland.appId !== "")
                return top.wayland.appId;
            const data = top.lastIpcObject;
            return data && data["class"] ? data["class"] : "";
        }
        return "";
    }

    onActiveChanged: {
        if (active)
            resumed();
        else
            state = null;
    }

    Connections {
        target: Capabilities

        // A capabilities event with `stages` (plugin reloaded, flag pushed): the strip sends `op:on` again (contract 7).
        function onFeaturesChanged(): void {
            if (root.active)
                root.resumed();
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name !== "grassfield")
                return;
            const parsed = StagesState.parse(event.data);
            if (!parsed)
                return;
            root.reason = parsed.reason;
            if (parsed.complete || !parsed.on)
                root.state = parsed; // an older plugin's full event, or Stages off (no monitors to fetch)
            else
                root.fetchState();
            if (parsed.reason === "no-strip" || parsed.reason === "interrupted")
                root.resendNeeded(parsed.reason);
        }
    }

    Process {
        id: stateFetch

        command: ["hyprctl", "grassfield-stages"]
        stdout: StdioCollector {
            onStreamFinished: root.applyFetched(text)
        }
        onRunningChanged: {
            if (!running && root.fetchAgain) {
                root.fetchAgain = false;
                running = true;
            }
        }
    }

    // Test hook (tests/visual waits on it): `qs ipc call stages status` is "unavailable" without `stages-available`,
    // else "off" | "ready" with the number of strip stages per monitor.
    IpcHandler {
        target: "stages"

        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            if (!root.available)
                return "unavailable";
            if (!root.on)
                return root.enabled ? "waiting" : "off";
            const names = Object.keys(root.state.monitors);
            return "ready " + names.map(n => n + "=" + StagesState.stripStages(root.state.monitors[n]).length).join(",");
        }

        // Keyboard and scripting access (the strip itself takes no keyboard): the n-th strip stage (1 = most recent) of the
        // focused output comes forward, as a click on its tile.
        function activate(position: int): string {
            const mon = root.monitorState(Compositor.focusedScreenName);
            const stage = mon ? StagesState.stripStages(mon)[position - 1] : undefined;
            return stage && root.send({op: "activate", stage: stage.id}) ? "ok" : "refused";
        }

        // The focused window becomes a stage of its own (macOS: drag it to the strip).
        function newStage(): string {
            const w = Compositor.activeWindow();
            return w && root.send({op: "move", address: "0x" + Minimized.normalizeAddress(w.address), stage: "new"}) ? "ok" : "refused";
        }

        function enable(on: bool): string {
            if (!VisualFixtures.dev)
                return "refused";
            Settings.setStagesEnabled(on);
            return "ok";
        }
    }
}
