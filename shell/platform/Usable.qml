pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell

// Gate P5 marker: the session is "usable" once the menu bar and the Dock of every output have drawn a first frame (after the
// session's entrance, ADR-0040 step 6: both wait for it, so P5 counts the wallpaper and the entrance). The
// shell logs one line, "grassfield-shell: usable (...)", when that holds; scripts/gates/session-start.sh measures the
// time from the session start to this line in the journal. UsableProbe.qml, placed in the menu bar and Dock windows,
// reports the first frame of each. A Dock window that is not shown (`active` false) is not waited for.
QtObject {
    id: root

    // "bar:<output>" and "dock:<output>" -> a frame was drawn.
    property var drawnKeys: ({})
    // "dock:<output>" -> the window is shown and will draw.
    property var absentKeys: ({})
    property bool announced: false

    function report(kind: string, screenName: string, drawn: bool): void {
        if (announced)
            return;
        const key = kind + ":" + screenName;
        if (drawn)
            root.drawnKeys[key] = true;
        else
            root.absentKeys[key] = true;
        check();
    }

    function check(): void {
        const screens = Quickshell.screens;
        if (announced || screens.length === 0)
            return;
        let docks = 0;
        for (let i = 0; i < screens.length; i++) {
            const name = screens[i].name;
            if (!root.drawnKeys["bar:" + name])
                return;
            if (root.drawnKeys["dock:" + name])
                docks++;
            else if (!root.absentKeys["dock:" + name])
                return;
        }
        if (docks === 0)
            return;
        announced = true;
        console.info("grassfield-shell: usable (menu bar and Dock drawn on", screens.length, "output(s))");
    }
}
