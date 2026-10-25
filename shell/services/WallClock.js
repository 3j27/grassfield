.pragma library

// The next tick of a wall clock, from epoch milliseconds only (shell/services/WallClock.qml). Every time zone in use
// today is a whole number of minutes from UTC, so a local minute (and second) starts exactly when the epoch one does,
// whatever daylight saving time does to the local hour.

// Milliseconds until the next whole unit (60000: minute, 1000: second) plus a small margin, so the timer fires just
// after the boundary; at most capMs (a Timer counts monotonic time, which stops while the machine sleeps: the cap bounds
// how stale the clock can be after a wake); never below 1 and never NaN, whatever the inputs (a missing cap is the unit,
// a missing unit a minute, an instant that is not a finite number the epoch): a clock must never spin.
function msToNext(nowMs, unitMs, capMs) {
    const unit = unitMs > 0 ? unitMs : 60000;
    const cap = capMs > 0 ? capMs : unit;
    const now = Number.isFinite(nowMs) ? nowMs : 0;
    const rest = unit - (((now % unit) + unit) % unit);
    return Math.max(1, Math.min(cap, rest + 2));
}

// The number of the unit an instant falls in: the displayed value changes exactly when this does.
function unitIndex(nowMs, unitMs) {
    return Math.floor(nowMs / unitMs);
}
