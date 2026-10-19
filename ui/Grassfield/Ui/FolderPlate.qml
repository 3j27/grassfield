pragma Singleton
import QtQuick

// The plates of folder icons: what a folder looks like under a plain symbol, so the symbol's shade never depends on
// constants calibrated for one icon theme. The RAW icon's pixels under the symbol are read once per (icon file, size
// bucket) as a small grid of samples (FolderStyle.sampleBox, by one FolderIcon at a time, application wide); the plate of any
// combination of icon mode, folder colour and appearance is then computed from those samples (FolderStyle.plateThrough:
// the arithmetic of the MultiEffect shaders), so a new colour or mode never costs another read. No grab of the visible icon.
QtObject {
    id: root

    // rawKey -> flat sample array (FolderStyle.sampleBox) or null (it could not be read). Bumped on every change: bindings read it.
    property var samples: ({})
    property int revision: 0
    // The raw key being read now, "" when none: one read at a time in the whole application.
    property string busy: ""
    // Bound on the cache; cleared when exceeded, read again on demand.
    readonly property int limit: 512
    // Number of raw reads stored (tests).
    property int count: 0
    // Plates computed from the samples (full key -> plate), bounded the same way. One object changed in place: a binding that
    // computes a plate must not depend on, or be invalidated by, its own cache.
    readonly property var cache: ({plates: {}, n: 0})
    readonly property int derivedLimit: 4096

    // The size bucket of an icon edge: the smallest bucket that holds it, else the largest.
    function bucketOf(size) {
        const buckets = Tokens.folderIconPlateBuckets;
        for (let i = 0; i < buckets.length; i++) {
            if (size <= buckets[i])
                return buckets[i];
        }
        return buckets[buckets.length - 1];
    }

    function rawKeyOf(source, size) {
        return String(source) + "|" + root.bucketOf(size);
    }

    // The plate of a combination ({dark, light, hue, ref}, FolderStyle.plateThrough), undefined (the icon is not read yet), or
    // null (it could not be read: the estimate serves). Reads `revision`: use it in a binding. `modeTint`: the icon tint
    // as a string, "" unless the mode is Tinted; `folderTint`: the folder colour as a string, "" when the icon is not recoloured.
    function plateOf(rawKey, mode, modeTint, folderTint, dark) {
        const r = root.revision;
        const s = r >= 0 ? root.samples[rawKey] : undefined;
        if (s === undefined || s === null)
            return s;
        const key = rawKey + "|" + mode + "|" + modeTint + "|" + folderTint + "|" + (dark ? "d" : "l");
        let plate = root.cache.plates[key];
        if (plate === undefined) {
            if (root.cache.n >= root.derivedLimit) {
                root.cache.plates = {};
                root.cache.n = 0;
            }
            plate = FolderStyle.plateThrough(s, mode, modeTint === "" ? "#000000" : modeTint, folderTint !== "", folderTint,
                                             FolderStyle.rgbOf(dark ? Tokens.folderIconPlateBackdropDark : Tokens.folderIconPlateBackdropLight), Tokens);
            root.cache.plates[key] = plate;
            root.cache.n++;
        }
        return plate;
    }

    // Whether the caller should read `key` (nobody else does now and it is not known).
    function claim(key) {
        if (root.samples[key] !== undefined || root.busy !== "")
            return false;
        root.busy = key;
        return true;
    }

    // The claimant went away without a result: another icon may read it.
    function release(key) {
        if (root.busy !== key)
            return;
        root.busy = "";
        root.revision++;
    }

    // The samples of a raw key (null = they could not be read: the caller keeps the estimate; remembered so it is not retried).
    function store(key, samplesRead) {
        if (root.count >= root.limit) {
            root.samples = ({});
            root.cache.plates = {};
            root.cache.n = 0;
            root.count = 0;
        }
        root.samples[key] = samplesRead;
        root.count++;
        if (root.busy === key)
            root.busy = "";
        root.revision++;
    }

    // Test hook: forget everything.
    function reset() {
        root.samples = ({});
        root.cache.plates = {};
        root.cache.n = 0;
        root.busy = "";
        root.count = 0;
        root.revision++;
    }
}
