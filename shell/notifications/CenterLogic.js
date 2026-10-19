.pragma library

// Pure logic of the Notifications column (unit-tested, tests/unit/tst_notifcenter.qml).

// Key of the card that takes the keyboard focus after a card (or a whole app group) was cleared. `rows` are the
// displayed rows AFTER the model changed ({key, appName}, in display order); `at` is the slot the cleared card
// had (for a group, the slot of its first card) and `app` its app. In order:
//  1. the card now in the same slot when it is the same app's (the next one of the group, or the one the clear
//     revealed in a collapsed group);
//  2. else the app's new last card (the cleared card was the last of its group, others remain before it);
//  3. else (the group is gone) the card now in the same slot, i.e. the next group's first card;
//  4. else the previous card; "" when no card is left.
// Never another group's card while the same group still has a displayed one.
function focusAfterClear(rows, at, app) {
    const same = i => i >= 0 && i < rows.length && rows[i].appName === app;
    if (same(at))
        return rows[at].key;
    if (same(at - 1))
        return rows[at - 1].key;
    if (at < rows.length)
        return rows[at].key;
    return rows.length > 0 ? rows[Math.min(at, rows.length) - 1].key : "";
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
