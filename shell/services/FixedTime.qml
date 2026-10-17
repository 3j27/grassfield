pragma Singleton
import QtQuick
import Quickshell

// Dev-only clock freeze for deterministic screenshots (tests/visual): with GRASSFIELD_DEV=1 and
// GRASSFIELD_FIXED_TIME (e.g. "2026-10-17T09:41:00") every clock shows that instant. Inert otherwise.
QtObject {
    readonly property string fixed: Quickshell.env("GRASSFIELD_DEV") === "1" ? Quickshell.env("GRASSFIELD_FIXED_TIME") : ""

    // The instant to display: the frozen one in dev when set, else the real one.
    function date(real: date): date {
        return fixed !== "" ? new Date(fixed) : real;
    }
}
