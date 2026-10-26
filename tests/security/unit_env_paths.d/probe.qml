pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.security.lock

// Probe of tests/security/unit_env_paths.sh: which Lock singleton did `import qs.security.lock` load? The real one
// (shell/security/lock/Lock.qml: lockState "unlocked" offscreen, devHooks a bool) or the hostile one the script put in a
// `qs/security/lock` directory on a QML search path (lockState "EVIL-LOCK", no devHooks). Prints one "unit-env:" line.
ShellRoot {
    Timer {
        running: true
        interval: 300
        onTriggered: {
            console.log("unit-env: lockState=" + Lock.lockState + " devHooks=" + (typeof Lock.devHooks));
            Qt.exit(0);
        }
    }
}
