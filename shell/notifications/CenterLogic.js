.pragma library

// Pure logic of the Notifications column (unit-tested, tests/unit/tst_notifcenter.qml).

// Key of the card that takes the keyboard focus when the focused card `lost` ({key, app, rank}: its group and its rank from the
// group's top, noted while it was displayed) LEFT the displayed rows (hidden by an arrival pushing it out of a collapsed group,
// by "Show Less" or a collapse, removed by a clear, an expiry or the app, any number of them in one event-loop turn). `oldKeys`
// are the displayed keys in display order as of the last settled state, `rows` the displayed rows NOW ({key, appName}). Only
// `rows` decides what exists; `oldKeys` only gives the visual neighbourhood. In order:
//  1. the card now in the same slot of the same group (same rank, clamped to the group's last displayed card);
//  2. else (the group is gone) the first card after the lost one's old place that is still displayed (the next group);
//  3. else the nearest card before it; else the first row; "" when no card is left.
function focusAfterGone(lost, oldKeys, rows) {
    const group = rows.filter(r => r.appName === lost.app);
    if (group.length > 0)
        return group[Math.min(Math.max(lost.rank, 0), group.length - 1)].key;
    const alive = {};
    rows.forEach(r => alive[r.key] = true);
    const at = oldKeys.indexOf(lost.key);
    if (at >= 0) {
        for (let i = at + 1; i < oldKeys.length; i++) {
            if (alive[oldKeys[i]])
                return oldKeys[i];
        }
        for (let i = at - 1; i >= 0; i--) {
            if (alive[oldKeys[i]])
                return oldKeys[i];
        }
    }
    return rows.length > 0 ? rows[0].key : "";
}

// Pointer-over counts per app: a card, and the x that sticks out of its corner, each count while hovered, so the
// group controls stay while any part of any card of the app is under the pointer, whatever order the enter and
// leave events arrive in. Returns the new counts (never negative); the input is not changed.
function hoverStep(counts, app, over) {
    const next = Object.assign({}, counts);
    next[app] = Math.max(0, (next[app] || 0) + (over ? 1 : -1));
    return next;
}

function isHovered(counts, app) {
    return (counts[app] || 0) > 0;
}
