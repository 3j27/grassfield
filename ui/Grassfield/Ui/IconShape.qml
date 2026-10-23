pragma Singleton
import QtQuick

// The shape of icon files, for the own-tile rule of the icon appearance modes (docs/specs/ui.md "Icon shader"): an icon that is
// already a rounded square filling its box is not put inside the system plate a second time; its own tile is scaled onto the plate.
// What this keeps: per icon FILE (never per size, mode or frame), the edge of the icon's tile over its box (IconTile.js measure on
// the alpha mask read by TintedIcon through a Canvas), 0 when the icon is not a tile. Reads are claimed, a few at a time in the
// whole application, like FolderPlate; the result is looked up by a binding (reads `revision`).
QtObject {
    id: root

    // source (string) -> tile edge over the box (0: not a tile). Bumped on every change: bindings read it.
    property var sides: ({})
    property int revision: 0
    // Reads in flight now (claimed, not stored).
    property int busy: 0
    property int count: 0
    // Bound on the cache; past it the least recently used quarter is evicted and read again on demand.
    readonly property int limit: 1024
    readonly property var meta: ({claimed: {}, used: {}, tick: 0})

    // The tile edge of `source`: undefined (not read yet), 0 (not a tile) or a number in (0, 1]. Reads `revision`: use it in a binding.
    function sideOf(source) {
        const r = root.revision;
        const s = r >= 0 ? root.sides[source] : undefined;
        if (s !== undefined)
            root.meta.used[source] = ++root.meta.tick;
        return s;
    }

    // Whether the caller should read `source` (nobody else does now and it is not known; fewer than the allowed number are in flight).
    function claim(source) {
        if (root.sides[source] !== undefined || root.meta.claimed[source] === true || root.busy >= Tokens.iconModeOwnTileConcurrency)
            return false;
        root.meta.claimed[source] = true;
        root.busy++;
        return true;
    }

    // The claimant went away without a result: another icon may read it.
    function release(source) {
        if (root.meta.claimed[source] !== true)
            return;
        delete root.meta.claimed[source];
        root.busy--;
        root.revision++;
    }

    // The result of a read: the tile edge (0 when not a tile or when it could not be read).
    function store(source, side) {
        if (root.count >= root.limit)
            root.evict();
        if (root.sides[source] === undefined)
            root.count++;
        root.sides[source] = side;
        root.meta.used[source] = ++root.meta.tick;
        if (root.meta.claimed[source] === true) {
            delete root.meta.claimed[source];
            root.busy--;
        }
        root.revision++;
    }

    function evict() {
        const keys = Object.keys(root.sides);
        keys.sort((a, b) => (root.meta.used[a] || 0) - (root.meta.used[b] || 0));
        const drop = Math.max(1, Math.floor(keys.length / 4));
        for (let i = 0; i < drop; i++) {
            delete root.sides[keys[i]];
            delete root.meta.used[keys[i]];
        }
        root.count -= drop;
    }

    // Test hook: forget everything.
    function reset() {
        root.sides = ({});
        root.meta.claimed = ({});
        root.meta.used = ({});
        root.busy = 0;
        root.count = 0;
        root.revision++;
    }
}
