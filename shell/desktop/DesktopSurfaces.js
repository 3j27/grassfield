.pragma library

// Which screens carry what on the desktop (DesktopIcons.qml), pure. Every screen has the desktop surface (the empty-desktop
// menu, the rubber band, the keyboard); the icons are on ONE screen. This is the single place that decides which.

// The screen that shows the icons: the main display (`main`, MainDisplay.screenName: the choice in Settings > Displays, the dev
// override GRASSFIELD_DESKTOP_SCREEN, the built-in panel or the first screen), else the first screen, else "".
function iconsScreen(main, names) {
    if (main)
        return String(main);
    return Array.isArray(names) && names.length > 0 ? String(names[0] || "") : "";
}

// The icons are on this screen: it is that screen, and Show Desktop Items is on.
function iconsHere(name, iconsScreenName, showItems) {
    return typeof name === "string" && name !== "" && name === iconsScreenName && showItems === true;
}
