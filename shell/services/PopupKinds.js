.pragma library

// The popup kinds the Overlay draws (shell/overlay/Overlay.qml, its Loader's switch): Popups.open refuses any other, so no
// caller, IPC included, can map an empty overlay that takes the keyboard (the retired "about" did, review of ce69dc6).
// Unit-tested in tests/unit/tst_popupkinds.qml, which also holds this list to the Overlay's.

const kinds = ["system", "app", "appfile", "appwindow", "appbridge", "tray", "nowplaying", "volume", "network", "battery",
    "controlcenter", "dock", "dockstack", "forcequit", "confirm", "appabout", "notice", "tiling", "tilingSuggest", "sharePicker"];

function known(kind) {
    return kinds.indexOf(kind) >= 0;
}

// The kinds drawn as a Dialog (shell/overlay/Dialog.qml): an alert or a sheet, each with its own corner. tests/unit/
// tst_overlayblur.qml holds this list to the Overlay's components: a new kind built on Dialog that is not here fails it.
const dialogs = ["forcequit", "confirm", "appabout", "notice", "sharePicker"];

// The symbol a notice shows (ADR-0040 IQ-B1 B: its subject's, never the Grassfield mark): `symbol` when it names one, the
// information symbol otherwise. A caller that leaves it out passes undefined, or "undefined" through a string-typed parameter
// (Qt 6.11; the review of 52b2bec): both read as none.
function noticeSymbol(symbol) {
    return typeof symbol === "string" && symbol !== "" && symbol !== "undefined" && symbol !== "null" ? symbol : "info";
}

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
