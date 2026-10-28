import QtQuick

// Door of the system sections to the machine: read-only queries and guarded actions.
// Wi-Fi and Bluetooth go over D-Bus (queryBus, and act with an {op: ...} map); the Sound page runs wpctl (query, act with an argv).
// In a dev session (GRASSFIELD_DEV=1, a nested Hyprland on the owner's machine) an action never reaches the Backend:
// one "dev guard: <what> suppressed" line is logged and `suppressedNote` turns on (the pages show "dev: not applied").
// The Backend refuses the same things again (src/systemguard.cpp), so a mistake here still cannot act.
QtObject {
    id: root

    required property var backend
    readonly property bool dev: root.backend.devSession === true
    // An action was suppressed in this session.
    property bool suppressedNote: false
    // Reason of the last failed action per tag ("wifi.act", "bt.act", "audio.act"): the service's or the tool's own short
    // message, "-" when it gave none. An entry goes away when the next action of that tag starts or succeeds.
    property var errors: ({})

    function clearError(tag: string): void {
        if (root.errors[tag] === undefined)
            return;
        const e = Object.assign({}, root.errors);
        delete e[tag];
        root.errors = e;
    }

    // Read-only query: the answer arrives as backend.finished(tag, ok, output).
    function query(argv: var, tag: string): void {
        root.backend.query(argv, tag);
    }

    // Read-only D-Bus query ("wifi.state", "bt.state"): the answer, a JSON text, arrives as backend.finished(tag, ok, output).
    function queryBus(what: string, tag: string): void {
        root.backend.busQuery(what, tag);
    }

    // State-changing action. `spec` is an argv (wpctl) or an {op: ...} map (D-Bus), null for an invalid value (nothing runs).
    // Returns true when it was started.
    function act(what: string, spec: var, tag: string): bool {
        if (spec === null || spec === undefined)
            return false;
        if (root.dev) {
            console.info("dev guard: " + what + " suppressed");
            root.suppressedNote = true;
            return false;
        }
        root.clearError(tag);
        if (!Array.isArray(spec))
            return root.backend.busAct(what, spec, tag);
        return root.backend.act(what, spec, tag);
    }

    // A program started and left running (Backend.launch: Software Update's Update Now, Log Out…, Restart…). Returns true when
    // it started.
    function launch(what: string, argv: var): bool {
        if (root.dev) {
            console.info("dev guard: " + what + " suppressed");
            root.suppressedNote = true;
            return false;
        }
        return root.backend.launch(what, argv);
    }

    readonly property Connections results: Connections {
        target: root.backend

        function onFailed(tag: string, reason: string): void {
            if (!tag.endsWith(".act"))
                return;
            const e = Object.assign({}, root.errors);
            e[tag] = reason !== "" ? reason : "-";
            root.errors = e;
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (ok && tag.endsWith(".act"))
                root.clearError(tag);
        }
    }
}
