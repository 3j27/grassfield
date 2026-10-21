import QtQuick
import Quickshell
import qs.services

// GlanceApp during the start-up wait for the scope detection (tests/shell/glance_cancel.sh holds the probe back with a slow
// `sh`). GF_SCENARIO: none (Glance starts: the harness is sound), close (Esc), toggle (a second Space).
// The script checks whether the preview command ran; this file only drives the singleton.
ShellRoot {
    Component.onCompleted: {
        const scenario = Quickshell.env("GF_SCENARIO");
        GlanceApp.toggle(["/tmp/grassfield-glance-cancel-file"]);
        if (!GlanceApp.starting)
            console.log("glance-cancel: FAIL not waiting for the scope");
        if (scenario === "close")
            GlanceApp.close();
        else if (scenario === "toggle")
            GlanceApp.toggle(["/tmp/grassfield-glance-cancel-file"]);
        console.log("glance-cancel: starting=" + GlanceApp.starting + " open=" + GlanceApp.open);
    }

    Timer {
        interval: 4000
        running: true
        onTriggered: Qt.quit()
    }
}
