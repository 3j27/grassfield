import QtQuick
import Grassfield.Ui
import "../ShowDesktop.js" as ShowDesktop
import "../ShowDesktopFlow.js" as Flow

// Runs the Show Desktop flow (ShowDesktopFlow.js, a pure reducer) for the shell: it takes the compositor's events from
// `eventSource`, reads the context through the read* functions, hands events, timers and presses to the flow and runs what comes
// back: the dispatches in the order given (the hide of the parking workspace is always first), the record file (persistRequested),
// the timers, the keyboard for the desktop icons (focusDesktopRequested). Compositor.qml owns the one instance and gives it the
// real Hyprland; tests/unit/tst_showdesktopglue.qml loads this very file with a fake event source and a fake dispatcher.
Item {
    id: root

    visible: false

    // What it listens to and reads: the Hyprland object (an object with the signal rawEvent(event) whose event has name and data).
    property var eventSource: null
    property var readWindows: () => []
    property var readShown: () => []
    property var readFocused: () => ""
    property var readCurrentWorkspace: () => 0
    property var readLoaded: () => true
    property bool stages: false
    // What it does: send a Lua request to the compositor, read the window list again.
    property var dispatch: request => {}
    property var refreshWindows: () => {}

    // The waits (overridable by tests).
    property int checkMs: Tokens.showDesktopCheckMs
    property int verifyMs: Tokens.showDesktopVerifyMs
    property int refreshMs: Tokens.showDesktopRefreshMs
    property int recoverMs: Tokens.showDesktopRecoverMs
    property int recoverTries: Tokens.showDesktopRecoverTries

    property var flow: Flow.initial()
    readonly property var records: root.flow.records

    signal persistRequested(string text)
    signal focusDesktopRequested

    // What the flow reads at every call. The window list is only built when asked (every Hyprland event comes through here).
    function context(withWindows: bool): var {
        return {
            windows: withWindows ? root.readWindows() : [],
            shown: withWindows ? root.readShown() : [],
            currentWorkspace: root.readCurrentWorkspace(),
            focused: root.readFocused(),
            stages: root.stages,
            loaded: root.readLoaded(),
            lookbackEvents: 2,
            maxVerify: 3,
            maxRecover: root.recoverTries,
            maxActivationTries: 3
        };
    }

    // Runs a result of the flow: the new state, the dispatches in the order given, the record file, the timers.
    function step(res: var): var {
        root.flow = res.state;
        for (const l of res.logs) {
            if (l.level === "warn")
                console.warn(l.text);
            else
                console.info(l.text);
        }
        for (const request of res.dispatches)
            root.dispatch(request);
        if (res.persist)
            root.persistRequested(ShowDesktop.serialize(res.state.records));
        const timers = {activation: activation, check: check, verify: verify, recover: recover};
        for (const id of Object.keys(res.timers)) {
            if (res.timers[id] === "stop")
                timers[id].stop();
            else
                timers[id].restart();
        }
        if (res.focusDesktop)
            root.focusDesktopRequested();
        return res;
    }

    function handleEvent(name: string, data: string): void {
        root.step(Flow.onEvent(root.flow, root.context(Flow.needsWindows(root.flow, name, data)), name, data));
    }

    // Super+F3. The window positions come from Hyprland's window data, which is read again first (the model may be stale): the
    // press waits for the answer, at most refreshMs.
    function press(): void {
        const res = root.step(Flow.onPress(root.flow, root.context(true)));
        if (res.refresh) {
            root.refreshWindows();
            refresh.restart();
        }
    }

    // An activation by the shell itself (activate(), unminimize()): Show Desktop ends first. True when it was on.
    function endForActivation(): bool {
        return root.step(Flow.onActivate(root.flow, root.context(true))).ended;
    }

    function screensChanged(): void {
        root.step(Flow.onScreensChanged(root.flow, root.context(true)));
    }

    // The record file was read (text of the file): a record from an earlier run is recovered, whatever it says is validated.
    function recordsLoaded(text: string): void {
        root.step(Flow.onLoaded(root.flow, root.context(true), ShowDesktop.parse(text)));
    }

    Connections {
        target: root.eventSource
        ignoreUnknownSignals: true

        function onRawEvent(event: var): void {
            root.handleEvent(event.name, event.data);
        }
    }

    Timer {
        id: activation
        interval: root.checkMs
        onTriggered: root.step(Flow.onTimer(root.flow, root.context(true), "activation"))
    }

    Timer {
        id: check
        interval: root.checkMs
        onTriggered: root.step(Flow.onTimer(root.flow, root.context(true), "check"))
    }

    Timer {
        id: verify
        interval: root.verifyMs
        onTriggered: root.step(Flow.onTimer(root.flow, root.context(true), "verify"))
    }

    Timer {
        id: refresh
        interval: root.refreshMs
        onTriggered: root.step(Flow.onCapture(root.flow, root.context(true)))
    }

    // The windows still parked by a Show Desktop of a previous run: back at start, once the window list is known.
    Timer {
        id: recover
        interval: root.recoverMs
        onTriggered: root.step(Flow.onTimer(root.flow, root.context(true), "recover"))
    }
}
