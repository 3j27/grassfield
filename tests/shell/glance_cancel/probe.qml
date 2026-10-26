import QtQuick
import Quickshell
import qs.services

// GlanceApp during the start-up wait for the scope detection (tests/shell/glance_cancel.sh, a dev session). A dev session knows its
// scope at once, so the wait is made by hand: scopeKnown goes false (as while the uwsm-app probe of a real session is pending) and
// Apps.settleScope() ends it 0.6 s later, which is what the probe's answer does. GF_SCENARIO: none (Glance starts: the harness is
// sound), close (Esc), toggle (a second Space). The script checks whether the preview command ran; this file only drives the singletons.
ShellRoot {
    Component.onCompleted: {
        const scenario = Quickshell.env("GF_SCENARIO");
        Apps.scopeKnown = false;
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
        interval: 600
        running: true
        onTriggered: Apps.settleScope()
    }

    Timer {
        interval: 2500
        running: true
        onTriggered: Qt.quit()
    }
}
