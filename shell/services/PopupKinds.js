.pragma library

// The popup kinds the Overlay draws (shell/overlay/Overlay.qml, its Loader's switch): Popups.open refuses any other, so no
// caller, IPC included, can map an empty overlay that takes the keyboard (the retired "about" did, review of ce69dc6).
// Unit-tested in tests/unit/tst_popupkinds.qml, which also holds this list to the Overlay's.

const kinds = ["system", "app", "appfile", "appwindow", "appbridge", "tray", "nowplaying", "volume", "network", "battery",
    "controlcenter", "dock", "dockstack", "forcequit", "confirm", "appabout", "notice", "tiling", "tilingSuggest"];

function known(kind) {
    return kinds.indexOf(kind) >= 0;
}

// The kinds drawn as a Dialog (shell/overlay/Dialog.qml): an alert or a sheet, each with its own corner. tests/unit/
// tst_overlayblur.qml holds this list to the Overlay's components: a new kind built on Dialog that is not here fails it.
const dialogs = ["forcequit", "confirm", "appabout", "notice"];

// The corner of the Overlay's blur region behind a popup of `kind` (ADR-0039 step 4, G2): a dialog's own (`dialogCorner`,
// radius.alert or radius.sheet, read from the loaded Dialog; a menu's while it is not loaded), Now Playing's tile, a menu's
// for the rest.
function blurCorner(kind, dialogCorner, tokens) {
    if (dialogs.indexOf(kind) >= 0 && typeof dialogCorner === "number")
        return dialogCorner;
    if (kind === "nowplaying")
        return tokens.quicksettingsRadiusTile;
    return tokens.radiusMenu;
}
