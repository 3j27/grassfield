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

// Key of the card that takes the keyboard focus when the focused card `key` LEFT the displayed rows (hidden by an arrival
// pushing it out of a collapsed group, by "Show Less" or a collapse, removed by a clear, an expiry or the app). `oldRows`
// and `rows` are the displayed rows before and after ({key, appName}, in display order). In order:
//  1. the card that now occupies the same slot of the same group (same rank from the group's top; the card that moved up
//     into it, the one an arrival pushed it down to, or the one a removal revealed);
//  2. else the group's last displayed card (fewer cards displayed than its rank);
//  3. else (the group is gone) the first card after the group's old place that is still displayed;
//  4. else the nearest card before it; "" when no card is left. undefined when `key` was not displayed.
function focusAfterGone(oldRows, rows, key) {
    const at = oldRows.findIndex(r => r.key === key);
    if (at < 0)
        return undefined;
    const app = oldRows[at].appName;
    let rank = 0;
    for (let i = 0; i < at; i++) {
        if (oldRows[i].appName === app)
            rank++;
    }
    const group = rows.filter(r => r.appName === app);
    if (group.length > 0)
        return group[Math.min(rank, group.length - 1)].key;
    const alive = {};
    rows.forEach(r => alive[r.key] = true);
    for (let i = at + 1; i < oldRows.length; i++) {
        if (alive[oldRows[i].key])
            return oldRows[i].key;
    }
    for (let i = at - 1; i >= 0; i--) {
        if (alive[oldRows[i].key])
            return oldRows[i].key;
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
