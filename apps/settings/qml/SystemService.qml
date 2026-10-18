import QtQuick

// Door of the system sections to the machine: read-only queries and guarded actions.
// In a dev session (GRASSFIELD_DEV=1, a nested Hyprland on the owner's machine) an action never reaches the Backend:
// one "dev guard: <what> suppressed" line is logged and `suppressedNote` turns on (the pages show "dev: not applied").
// The Backend refuses the same things again (src/systemguard.cpp), so a mistake here still cannot act.
QtObject {
    id: root

    required property var backend
    readonly property bool dev: root.backend.devSession === true
    // An action was suppressed in this session.
    property bool suppressedNote: false

    // Read-only query: the answer arrives as backend.finished(tag, ok, output).
    function query(argv: var, tag: string): void {
        root.backend.query(argv, tag);
    }

    // State-changing action. `argv` is null for an invalid value (nothing runs). Returns true when it was started.
    function act(what: string, argv: var, tag: string): bool {
        if (argv === null || argv === undefined)
            return false;
        if (root.dev) {
            console.info("dev guard: " + what + " suppressed");
            root.suppressedNote = true;
            return false;
        }
        return root.backend.act(what, argv, tag);
    }
}
