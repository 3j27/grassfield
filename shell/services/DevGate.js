.pragma library

// The one dev/test gate of the shell (GF-AUDIT-001 SEC-03, SEC-04; docs/specs/security.md "Dev gate").
//
// Dev hooks (IPC test hooks, the nested-only behaviour of the lock, idle and sleep modules) run only in a dev session:
// GRASSFIELD_DEV exactly "1" AND GRASSFIELD_SESSION not "1". The packaged session config sets GRASSFIELD_SESSION=1
// (config/hypr/session.lua), so a GRASSFIELD_DEV=1 that leaks into a real session (environment.d, a uwsm env file, an
// import into the user manager) changes nothing there. The nested dev session never sets GRASSFIELD_SESSION
// (scripts/dev/devenv.sh unsets an inherited one). Pure: unit-tested by tests/security/tst_devgate.qml.
//
// Arguments are the raw values of Quickshell.env("GRASSFIELD_DEV") and Quickshell.env("GRASSFIELD_SESSION"); anything
// but those exact strings (undefined, null, "", "true", " 1") leaves the gate closed.
function allowed(devValue, sessionValue) {
    return devValue === "1" && sessionValue !== "1";
}

// Answer of a gated IPC function outside a dev session.
var REFUSED = "refused";
