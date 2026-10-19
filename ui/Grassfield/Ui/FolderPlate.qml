pragma Singleton
import QtQuick

// The measured plates of folder icons: what the folder looks like under a plain symbol, read once from the drawn icon
// per (icon, size, icon mode, mode tint, folder colour) so the symbol's shade never depends on constants calibrated for
// one icon theme (FolderStyle.plateFromPixels). Shared by every FolderIcon: a combination is measured by one of them (the
// claimant) while the others wait; no per-frame work, one grab and one small pixel read per combination.
QtObject {
    id: root

    // key -> {dark, light, hue} (FolderStyle.plateFromPixels). Bumped on every change: bindings read it.
    property var plates: ({})
    property int revision: 0
    // Combinations being measured (key -> true); a claimant that goes away releases its claim.
    property var claims: ({})
    // Bound on the cache (arbitrary typed colours); cleared when exceeded, measured again on demand.
    readonly property int limit: 512
    property int count: 0

    // The plate of a combination, or undefined (not measured yet). Reads `revision`: use it in a binding.
    function plateOf(key) {
        const r = root.revision;
        return r >= 0 ? root.plates[key] : undefined;
    }

    // Whether the caller should measure `key` (nobody else does and it is not known).
    function claim(key) {
        if (root.plates[key] !== undefined || root.claims[key])
            return false;
        root.claims[key] = true;
        return true;
    }

    function release(key) {
        if (!root.claims[key])
            return;
        delete root.claims[key];
        root.revision++;
    }

    // A measured plate (null = it could not be measured: the caller keeps the estimate; remembered so it is not retried).
    function store(key, plate) {
        if (root.count >= root.limit) {
            root.plates = ({});
            root.count = 0;
        }
        root.plates[key] = plate;
        root.count++;
        delete root.claims[key];
        root.revision++;
    }

    // Test hook: forget everything.
    function reset() {
        root.plates = ({});
        root.claims = ({});
        root.count = 0;
        root.revision++;
    }
}
