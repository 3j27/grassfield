import QtQuick
import Grassfield.Ui
import "WallClock.js" as Tick

// The clock of the menu bar, the Clock and Calendar widgets and the lock screen (macOS: the clock moves on the minute,
// whatever the time zone does). It replaces Quickshell's SystemClock: in 0.3.1 SystemClock computes its next tick from
// local time, so in the repeated hour of a daylight saving fall-back its target lies an hour in the past and it restarts
// a 1 ms timer about 800 times a second until the hour ends (found 2026-10-25; a bare SystemClock under TZ=Europe/Paris
// logs "QTimer::start: negative intervals" 2379 times in 3 s, none under TZ=UTC). Here the next tick comes from epoch
// milliseconds (WallClock.js), which no time zone change moves. `date` changes only when the displayed unit does; the
// timer wakes at most every `Tokens.menubarClockMaxWaitMs`, so the time is right soon after a wake from sleep, and a new
// clock is right at once (the lock view is created with each lock surface).
QtObject {
    id: root

    property bool enabled: true
    // Seconds precision (the analog Clock widget's seconds hand); minutes otherwise.
    property bool seconds: false
    property date date: new Date()

    readonly property int unitMs: seconds ? 1000 : 60000

    function refresh(): void {
        const now = Date.now();
        if (Tick.unitIndex(now, unitMs) !== Tick.unitIndex(date.getTime(), unitMs))
            date = new Date(now);
        if (enabled) {
            timer.interval = Tick.msToNext(now, unitMs, Tokens.menubarClockMaxWaitMs);
            timer.restart();
        } else {
            timer.stop();
        }
    }

    onEnabledChanged: refresh()
    onSecondsChanged: refresh()
    Component.onCompleted: refresh()

    readonly property Timer timer: Timer {
        repeat: false
        onTriggered: root.refresh()
    }
}
