pragma Singleton
import QtQuick
import Quickshell
import qs.lib

// Dev-only clock freeze for deterministic screenshots (tests/visual): in a dev session (Mode.dev: GRASSFIELD_DEV=1 and
// not GRASSFIELD_SESSION=1, like every dev hook) with GRASSFIELD_FIXED_TIME (dev plumbing, Mode.devValue) (e.g. "2026-10-17T09:41:00") every clock
// shows that instant. Inert otherwise, also when GRASSFIELD_DEV leaks into a real session.
QtObject {
    readonly property string fixed: Mode.devValue("FIXED_TIME")

    // The instant to display: the frozen one in dev when set, else the real one.
    function date(real: date): date {
        return fixed !== "" ? new Date(fixed) : real;
    }
}
