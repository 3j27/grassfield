.pragma library

// The popup kinds the Overlay draws (shell/overlay/Overlay.qml, its Loader's switch): Popups.open refuses any other, so no
// caller, IPC included, can map an empty overlay that takes the keyboard (the retired "about" did, review of ce69dc6).
// Unit-tested in tests/unit/tst_popupkinds.qml, which also holds this list to the Overlay's.

const kinds = ["system", "app", "appfile", "appwindow", "appbridge", "tray", "nowplaying", "volume", "network", "battery",
    "controlcenter", "dock", "dockstack", "forcequit", "confirm", "appabout", "notice", "tiling", "tilingSuggest"];

function known(kind) {
    return kinds.indexOf(kind) >= 0;
}
