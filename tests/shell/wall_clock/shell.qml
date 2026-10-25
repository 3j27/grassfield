pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.services

// The REAL WallClock (shell/services/WallClock.qml), offscreen under qs (scripts/dev/test.sh: `qs -p tests/shell/wall_clock`;
// prints "wall-clock: PASS" or the failures). Review of cf6d3df: a Clock widget is created small (a minute clock) and
// then made medium (seconds); the switch must take the seconds schedule at once, not after the minute clock's next wake.
// - a minute clock waits for its minute or the cap, never less than 1 ms;
// - switching to seconds waits at most a second at once, and `date` then changes every second;
// - disabled: the timer stops; enabled again: it runs and `date` is current.
ShellRoot {
    id: root

    property var failures: []
    property int dateChanges: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    WallClock {
        id: clock
        onDateChanged: root.dateChanges++
    }

    // After every Component.onCompleted (the clock's own refresh among them; their order is not defined).
    Component.onCompleted: Qt.callLater(start)

    function start(): void {
        check("a minute clock runs", clock.timer.running);
        check("a minute clock waits 1 ms or more", clock.timer.interval >= 1);
        check("a minute clock waits at most the cap", clock.timer.interval <= 10000 + 2);
        clock.seconds = true;
        check("seconds at once (interval " + clock.timer.interval + ")", clock.timer.interval >= 1 && clock.timer.interval <= 1002);
        dateChanges = 0;
        settle.start();
    }

    Timer {
        id: settle
        interval: 2600
        onTriggered: {
            root.check("date changed every second (" + root.dateChanges + " changes in 2.6 s)", root.dateChanges >= 2 && root.dateChanges <= 3);
            clock.enabled = false;
            root.check("disabled: the timer stops", !clock.timer.running);
            clock.enabled = true;
            root.check("enabled again: the timer runs", clock.timer.running);
            root.check("enabled again: date is current", Math.abs(Date.now() - clock.date.getTime()) < 1100);
            if (root.failures.length === 0) {
                console.log("wall-clock: PASS");
                Qt.exit(0);
            } else {
                console.log("wall-clock: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }
}
