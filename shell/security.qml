// grassfield-security root (ADR-0041 step 1, S1; ADR-0010 "Separate security process", the owner's SQ-1 B of 2026-10-29).
// A second Quickshell process of the Grassfield session, `qs -n -p /usr/share/grassfield/shell/security.qml`
// (grassfield-security.service), beside the UI (`qs -n -p /usr/share/grassfield/shell`, grassfield-shell.service). The
// file is a root of its own next to shell.qml, so `qs.*` resolves from the same directory as the UI's root and the
// security modules move here one by one without moving a file (S2: the lock, idle and the sleep inhibitor, with every
// lock caller; S3: the polkit agent; S4: safe mode). At S1 it hosts nothing moved yet: its IPC target `security` (what
// grassfield-security-status and the measurements read) and the "ready" line its start time is measured from. Nothing
// here locks, unlocks, authorizes or draws; the UI keeps every security module until S2.
// GF-115: loaded by path from the system tree only (the unit); R12: never reloaded on a file change.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    // A reload is a security event (shell/security/lock/Lock.qml): never on a file change. Re-applied by every reload
    // (Quickshell resets it to true), as the UI's root does.
    settings.watchFiles: false

    // What the process hosts: `starting` at S1 (nothing moved yet); the names of the modules as they move in.
    readonly property string hosted: "starting"
    // The heartbeat's sequence number: one more per answer. S2 makes the UI read "a sequence that stops" as stale, which
    // its refusals then treat as locked.
    property int sequence: 0

    // The start-time measurement reads this line in the journal (the unit's "Started" line is the start).
    Component.onCompleted: console.info("grassfield-security: ready (hosting " + root.hosted + ")")

    IpcHandler {
        target: "security"

        // The process's state: `starting` at S1. Never private state.
        function state(): string {
            return root.hosted;
        }

        // The state and a sequence number that grows with every answer.
        function heartbeat(): string {
            root.sequence += 1;
            return root.hosted + " " + root.sequence;
        }
    }
}
