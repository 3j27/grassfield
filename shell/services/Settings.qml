pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.store
import "../dock/Geometry.js" as DockGeometry

// User configuration facade over SettingsStore (grassfield.json, contract version 1).
// Keys are documented in docs/specs/ui.md.
Singleton {
    id: root

    // GRASSFIELD_CONFIG_HOME (dev) wins; otherwise $XDG_CONFIG_HOME/grassfield.
    readonly property string configDir: {
        const dev = Quickshell.env("GRASSFIELD_CONFIG_HOME");
        if (dev)
            return dev;
        const xdg = Quickshell.env("XDG_CONFIG_HOME");
        return (xdg ? xdg : Quickshell.env("HOME") + "/.config") + "/grassfield";
    }

    // Validated by the store (out-of-range or unknown values fall back to the schema defaults).
    readonly property string appearance: store.appearance
    readonly property bool dark: store.appearance !== "light"
    readonly property real transparency: store.transparency
    readonly property string materialProfile: store.materialProfile
    readonly property bool reduceTransparency: store.data.accessibility.reduceTransparency
    readonly property bool reduceMotion: store.data.accessibility.reduceMotion
    readonly property bool increaseContrast: store.data.accessibility.increaseContrast === true
    readonly property real textSize: store.textSize
    readonly property var dockPinned: store.dockPinned
    readonly property int dockSize: store.dockSize
    // Metrics of the Dock at the stored tile size (what the others reserve around it; the Dock itself follows a live resize).
    readonly property string dockPosition: store.dockPosition
    readonly property var dockMetrics: DockGeometry.metrics(dockSize, {
        iconSize: Tokens.dockIconSize,
        padding: Tokens.dockPadding,
        indicatorSize: Tokens.dockIndicatorSize,
        spacing: Tokens.dockSpacing,
        bottomMargin: Tokens.dockBottomMargin,
        separatorHeight: Tokens.dockSeparatorHeight,
        badgeSize: Tokens.dockBadgeSize,
        radiusIcon: Tokens.radiusDockIcon
    })
    // What the Dock keeps clear on its edge, whether or not it hides (the desktop icons, the widgets and the Apps panel stay put).
    readonly property var dockFootprint: DockGeometry.footprint(dockPosition, dockMetrics, false)
    readonly property real dockMagnification: store.dockMagnification
    readonly property bool dockMagnificationEnabled: store.data.dock.magnificationEnabled
    readonly property bool dockAutohide: store.data.dock.autohide
    readonly property var dockRecent: store.dockRecent
    readonly property var dockFolders: store.dockFolders
    readonly property var dockStackOptions: store.dockStackOptions
    readonly property bool dockShowRecents: store.data.dock.showRecents
    readonly property bool dockMinimizeIntoApp: store.data.dock.minimizeIntoApp
    readonly property bool dockAnimateOpening: store.data.dock.animateOpening
    readonly property bool dockShowIndicators: store.data.dock.showIndicators
    readonly property string dockMinimizeEffect: store.dockMinimizeEffect

    readonly property string accentColor: store.accentColor
    readonly property string iconMode: store.iconMode
    readonly property string iconTint: store.iconTint
    readonly property string folderColor: store.folderColor

    // grassfield.json has been read at least once.
    readonly property bool loaded: store.loaded
    // ... and is valid (false while it is malformed): the pointer theme acts on defaults only then.
    readonly property bool validRead: store.validRead
    readonly property bool writeBlocked: store.writeBlocked
    readonly property int pointerSize: store.pointerSize
    readonly property string pointerOutlineColor: store.pointerOutlineColor
    readonly property string pointerFillColor: store.pointerFillColor

    // Wallpaper settings (ADR-0016), complete and valid; see ui/Grassfield/Ui/WallpaperConfig.js.
    readonly property var wallpaper: store.wallpaper

    readonly property bool notificationsDnd: store.data.notifications.dnd
    readonly property string notificationsPreviews: store.notificationsPreviews
    readonly property string titlebarDoubleClick: store.titlebarDoubleClick
    readonly property bool windowsTilingEdges: store.data.windows.tilingEdges
    readonly property bool windowsTilingMenuBar: store.data.windows.tilingMenuBar
    readonly property bool windowsTilingMargins: store.data.windows.tilingMargins
    readonly property int lockIdleMinutes: store.lockIdleMinutes

    readonly property bool desktopShowIcons: store.data.desktop.showIcons
    readonly property bool menubarShowBackground: store.data.menubar.showBackground
    readonly property string menubarAutoHide: store.menubarAutoHide
    readonly property bool menubarShowNowPlaying: store.data.menubar.showNowPlaying
    readonly property bool menubarShowSearch: store.data.menubar.showSearch
    readonly property string hotCornerTopLeft: store.hotCornerTopLeft
    readonly property string hotCornerTopRight: store.hotCornerTopRight
    readonly property string hotCornerBottomLeft: store.hotCornerBottomLeft
    readonly property string hotCornerBottomRight: store.hotCornerBottomRight

    function setHotCorner(corner: string, action: string): void {
        store.setHotCorner(corner, action);
    }

    function setDesktopShowIcons(value: bool): void {
        store.setDesktopShowIcons(value);
    }

    function setMenubarShowBackground(value: bool): void {
        store.setMenubarShowBackground(value);
    }

    function setMenubarAutoHide(value: string): void {
        store.setMenubarAutoHide(value);
    }

    function setAppearance(value: string): void {
        store.setAppearance(value);
    }

    function setTransparency(value: real): void {
        store.setTransparency(value);
    }

    function setReduceTransparency(value: bool): void {
        store.setReduceTransparency(value);
    }

    function setReduceMotion(value: bool): void {
        store.setReduceMotion(value);
    }

    function setIncreaseContrast(value: bool): void {
        store.setIncreaseContrast(value);
    }

    function setTextSize(value: real): void {
        store.setTextSize(value);
    }

    function setDockAutohide(value: bool): void {
        store.setDockAutohide(value);
    }

    function setDockSize(value: real): void {
        store.setDockSize(value);
    }

    function setDockPosition(value: string): void {
        store.setDockPosition(value);
    }

    function setDockMagnification(value: real, enabled: bool): void {
        store.setDockMagnification(value, enabled);
    }

    function setDockPinned(list: var): void {
        store.setDockPinned(list);
    }

    function setDockRecent(list: var): void {
        store.setDockRecent(list);
    }

    function setDockFolders(list: var): void {
        store.setDockFolders(list);
    }

    function setDockStackOptions(options: var): void {
        store.setDockStackOptions(options);
    }

    function setIconMode(value: string): void {
        store.setIconMode(value);
    }

    function setIconTint(value: string): void {
        store.setIconTint(value);
    }

    function setFolderColor(value: string): void {
        store.setFolderColor(value);
    }

    function setNotificationsDnd(value: bool): void {
        store.setNotificationsDnd(value);
    }

    function setNotificationsPreviews(value: string): void {
        store.setNotificationsPreviews(value);
    }

    SettingsStore {
        id: store
        configDir: root.configDir
    }
}
