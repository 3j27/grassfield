.pragma library

// The one queue of the secret sheets and the polkit sheet (ADR-0035 D-9, master-prompt R12), its pure logic
// (shell/security/SheetQueue.qml holds the state; tests/security/tst_sheetqueue.qml). One sheet on screen at a time, in
// arrival order: every sheet takes a place (a sequence number) when it arrives and keeps it until its sheet is gone from
// the screen (answered, cancelled or withdrawn, and the key sink's linger after it over); the first place is the one
// that may be on screen. The polkit agent holds at most one request at a time (Quickshell 0.3: a new one replaces the
// open one in the same sheet), so polkit has one place, taken when its first request arrives and kept while its sheet
// is present; each secret request has a place of its own.

// A new, empty queue: `next` the next place, `polkit` the polkit sheet's place (0: none), `secrets` [{id, seq}] in
// arrival order.
function create() {
    return {next: 1, polkit: 0, secrets: []};
}

function indexOf(q, id) {
    for (let i = 0; i < q.secrets.length; i++) {
        if (q.secrets[i].id === id)
            return i;
    }
    return -1;
}

function has(q, id) {
    return indexOf(q, id) >= 0;
}

// The polkit sheet is present (a request arrived, or its sheet is still on screen) or not. A sheet that is already
// present keeps its place; one that arrives takes the last place.
function setPolkit(q, present) {
    if (present && q.polkit === 0)
        q.polkit = q.next++;
    else if (!present)
        q.polkit = 0;
}

// A secret request takes the last place; false for an empty id or one already queued.
function addSecret(q, id) {
    if (typeof id !== "string" || id === "" || has(q, id))
        return false;
    q.secrets.push({id: id, seq: q.next++});
    return true;
}

function removeSecret(q, id) {
    const i = indexOf(q, id);
    if (i < 0)
        return false;
    q.secrets.splice(i, 1);
    return true;
}

// Whether a polkit request must wait: a secret sheet came before it. A polkit request that has no place yet (it is
// arriving) comes after every secret request queued now.
function polkitWaits(q) {
    for (let i = 0; i < q.secrets.length; i++) {
        if (q.polkit === 0 || q.secrets[i].seq < q.polkit)
            return true;
    }
    return false;
}

// The secret request that may be on screen: the first one, unless the polkit sheet came before it. "" for none.
function secretHead(q) {
    const first = q.secrets.length > 0 ? q.secrets[0] : null;
    return first !== null && (q.polkit === 0 || first.seq < q.polkit) ? first.id : "";
}

function count(q) {
    return q.secrets.length;
}
