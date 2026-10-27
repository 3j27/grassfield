pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n
import Grassfield.Ui
import qs.desktop
import qs.dock
import qs.launchpad
import qs.menubar
import qs.notifications
import qs.osd
import qs.overview
import qs.overlay
import qs.platform
import qs.saver
import qs.search
import qs.security.idle
import qs.security.lock
import qs.security.polkit
import qs.services
import qs.stages
import qs.switcher
import "platform/ExtensionStatus.js" as ExtensionStatus

// grassfield-shell root. Settings feed the design-system Appearance singleton; surfaces
// read Appearance and Tokens only.
ShellRoot {
    id: root

    // Never reload on file changes: a reload is a security event for the session lock (R12,
    // shell/security/lock/Lock.qml). Re-applied by every reload (Quickshell resets it to true).
    // Development restarts the shell instead (scripts/dev/shell-run.sh).
    settings.watchFiles: false

    // Instantiates the Translator singleton first: it installs the catalog (GRASSFIELD_LANG or system
    // locale) before the surfaces below evaluate their qsTr() strings.
    readonly property string language: Translator.language

    // The session configuration's watchers (keyboard.lua and mouse-trackpad.lua, SessionConfig, ADR-0031 amendment) start with
    // the shell: Quickshell makes a singleton only when it is first used, and nothing else uses it before a display trial.
    readonly property int sessionConfigReloads: SessionConfig.reloads

    // The formats of dates, times and numbers (region.formats, Settings > General > Language & Region): the Translator makes
    // them the default locale, so every Qt.locale() of the shell (menu bar clock, widgets, lock screen) follows.
    Binding {
        target: Translator
        property: "formats"
        value: Settings.regionFormats
    }

    Binding {
        target: Appearance
        property: "dark"
        value: Settings.dark
    }

    // Lock state and lock requests for the modules that must not import shell/security (Notifications, Search).
    Binding {
        target: SessionState
        property: "locked"
        value: Lock.locked
    }
    Binding {
        target: SessionState
        property: "saverShown"
        value: saver.shown
    }

    // The authorization state for the modules that must not import shell/security (the clipboard history, ADR-0034 Q11).
    Binding {
        target: SessionState
        property: "authorizing"
        value: authAgent.requestActive
    }

    Connections {
        target: SessionState

        function onLockRequested(reason: string): void {
            Lock.lock(reason);
        }
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: Settings.transparency
    }

    Binding {
        target: Appearance
        property: "reduceTransparency"
        value: Settings.reduceTransparency
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: Settings.reduceMotion
    }

    Binding {
        target: Appearance
        property: "increaseContrast"
        value: Settings.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: Settings.textSize
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: Settings.accentColor
    }

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: Settings.accentHighlight
    }

    // Adaptive glass: what lies behind it on each output, when known (ADR-0024 G-3).
    Binding {
        target: Appearance
        property: "backdrops"
        value: Backdrop.known
    }

    // Menu shortcuts: the macOS symbols on a Mac, the text on a PC (keyboard.shortcutStyle, owner decision 2026-10-26).
    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: MenuShortcut.style(Settings.keyboardShortcutStyle, SystemInfo.macDevice)
    }

    Binding {
        target: Appearance
        property: "iconMode"
        value: Settings.iconMode
    }

    Binding {
        target: Appearance
        property: "iconTintSetting"
        value: Settings.iconTint
    }

    Binding {
        target: Appearance
        property: "folderColorSetting"
        value: Settings.folderColor
    }

    // Screen magnification (Settings > Accessibility > Zoom): sent to the compositor once the settings are read, then on change.
    Binding {
        target: Zoom
        property: "ready"
        value: Settings.validRead
    }

    // Settings > Displays (ADR-0031): the backlight goes into the displays state the Settings app reads.
    Binding {
        target: Displays
        property: "backlight"
        value: Brightness.deviceAvailable ? {device: Brightness.device, level: Brightness.deviceLevel} : null
    }

    // Pointer size (Settings > Accessibility > Pointer): the compositor is asked for the new size live.
    Binding {
        target: Pointer
        property: "size"
        value: Settings.pointerSize
    }

    // Pointer colours: the cursor theme is regenerated (debounced, off the UI thread) and switched to; the state of the
    // build is written next to grassfield.json for the Settings app.
    Binding {
        target: Pointer
        property: "outlineColor"
        value: Settings.pointerOutlineColor
    }

    Binding {
        target: Pointer
        property: "fillColor"
        value: Settings.pointerFillColor
    }

    // The colours are the stored ones only once the file is read (a custom theme from an earlier session is kept until then).
    Binding {
        target: Pointer
        property: "colorsKnown"
        value: Settings.validRead
    }

    // A malformed grassfield.json is not a read: the compositor theme and the custom theme on disk stay as they are.
    Binding {
        target: Pointer
        property: "settingsFailed"
        value: Settings.writeBlocked
    }

    Binding {
        target: Pointer
        property: "statusPath"
        value: Settings.configDir + "/pointer-theme.json"
    }

    // One degraded-mode notice when the compositor extension is absent; withdrawn if it loads later.
    property string degradedNoticeKey: ""
    // Why it is absent (ADR-0009 "Amendment 2026-10-23", GF-033): the session loads no build that is not made for the
    // Hyprland that runs. The rebuild tool says whether none is (--status); with the opt-in setting
    // windows.rebuildExtension the shell builds it once in the background (--session) and says how it went.
    readonly property string extensionTool: "/usr/lib/grassfield/grassfield-compositor-rebuild"
    property string extensionVersion: ""
    property bool extensionRebuildTried: false
    // The build that needs rebuilding was made from an older Grassfield (ExtensionStatus "stale"): its notices speak of an
    // update to finish, never of the Hyprland version.
    property bool extensionStale: false

    // The degraded notice is shown once the compositor extension is known to be absent (Capabilities.absent: not at the
    // first timeout, a loaded plugin can answer late at login) and withdrawn when it is present.
    function syncDegradedNotice(): void {
        if (Capabilities.absent && degradedNoticeKey === "") {
            if (!extensionStatus.running) {
                extensionStatus.running = true;
                extensionStatusLate.restart();
            }
        } else if (!Capabilities.absent && degradedNoticeKey !== "") {
            Notifications.clear(degradedNoticeKey);
            degradedNoticeKey = "";
        }
    }

    // "Hyprland 0.56.2", or a generic name when the tool gave no version.
    function hyprlandName(): string {
        return extensionVersion !== "" ? qsTr("Hyprland %1").arg(extensionVersion) : qsTr("this version of Hyprland");
    }

    // The notice for the --status answer (`text`, "" when the tool is not there or did not answer in time).
    function postDegradedNotice(text: string): void {
        extensionStatusLate.stop();
        if (!Capabilities.absent || degradedNoticeKey !== "")
            return;
        const status = ExtensionStatus.parse(text);
        // The choice is ExtensionStatus.degradedNotice (unit tested: a stale build never gets a text naming Hyprland).
        const key = ExtensionStatus.degradedNotice(status, Settings.windowsRebuildExtension, extensionRebuildTried);
        console.info("grassfield: degraded notice posted (compositor extension absent: " + ExtensionStatus.notice(status) + ")");
        extensionVersion = ExtensionStatus.version(status);
        extensionStale = key.startsWith("stale");
        const rebuild = key.endsWith("-rebuilding");
        switch (key) {
        case "stale-rebuilding":
            // GF-083's wording: an update finishes at the next login (macOS: "Restart to finish installing").
            degradedNoticeKey = Notifications.postInternal(qsTr("Updating the compositor extension"), qsTr("Grassfield was updated, and its compositor extension is being updated in the background. Window titlebars and minimize come back once it is done, or after the next login."));
            break;
        case "stale-manual":
            degradedNoticeKey = Notifications.postInternal(qsTr("Log out to finish updating"), qsTr("Grassfield was updated. Run grassfield-compositor-rebuild in a terminal to update its compositor extension, then log out and back in. Window titlebars and minimize are unavailable until then."));
            break;
        case "mismatch-rebuilding":
            degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension needs a rebuild"), qsTr("It is not built for %1 yet. Window titlebars and minimize are unavailable while it is built in the background.").arg(hyprlandName()));
            break;
        case "mismatch-manual":
            degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension needs a rebuild"), qsTr("It is not built for %1 yet, so window titlebars and minimize are unavailable. Run grassfield-compositor-rebuild in a terminal, then log out and back in.").arg(hyprlandName()));
            break;
        default:
            degradedNoticeKey = Notifications.postInternal(qsTr("Compositor extension not loaded"), qsTr("Window titlebars and minimize are unavailable (compositor extension not loaded)."));
            return;
        }
        if (rebuild) {
            extensionRebuildTried = true;
            console.info("grassfield: compositor extension rebuild started");
            extensionSession.running = true;
        }
    }

    // The notice for the --session answer.
    function postRebuildResult(text: string): void {
        const status = ExtensionStatus.parse(text);
        const outcome = ExtensionStatus.resultNotice(status, extensionStale);
        console.info("grassfield: compositor extension rebuild: " + ExtensionStatus.outcome(status));
        if (outcome === "updated-loaded")
            Notifications.postInternal(qsTr("Compositor extension updated"), qsTr("It is up to date and active."));
        else if (outcome === "updated-built")
            Notifications.postInternal(qsTr("Log out to finish updating"), qsTr("The compositor extension was updated. Log out and back in to use it."));
        else if (outcome === "rebuilt-loaded")
            Notifications.postInternal(qsTr("Compositor extension rebuilt"), qsTr("It is built for %1 and loaded.").arg(hyprlandName()));
        else if (outcome === "rebuilt-built")
            Notifications.postInternal(qsTr("Compositor extension rebuilt"), qsTr("It is built for %1. Log out and back in to use it.").arg(hyprlandName()));
        else if (outcome === "cannot-build")
            Notifications.postInternal(qsTr("Compositor extension not rebuilt"), qsTr("The build tools are missing or another build is running. Run grassfield-compositor-rebuild in a terminal to see why."));
        else
            Notifications.postInternal(qsTr("Compositor extension not rebuilt"), qsTr("The build failed. Run grassfield-compositor-rebuild in a terminal to see why."));
    }

    Process {
        id: extensionStatus
        command: [root.extensionTool, "--status"]
        stdout: StdioCollector {
            onStreamFinished: root.postDegradedNotice(text)
        }
    }

    // No answer (the tool is not installed, or it hangs): the plain notice all the same.
    Timer {
        id: extensionStatusLate
        interval: 3000
        onTriggered: root.postDegradedNotice("")
    }

    Process {
        id: extensionSession
        command: [root.extensionTool, "--session"]
        stdout: StdioCollector {
            onStreamFinished: root.postRebuildResult(text)
        }
    }

    // GF-083: a package update leaves the old shell and compositor plugin running until the next login (macOS: "Restart to
    // finish installing"). One notice per run; nothing is shown while the versions are unknown.
    UpdateNotice {
        id: updateNotice
        property bool announced: false
        onUpdatePendingChanged: {
            if (updatePending && !announced) {
                announced = true;
                Notifications.postInternal(qsTr("Log out to finish updating"), qsTr("Grassfield was updated. Log out and back in to use the new version."));
            }
        }
    }

    // ADR-0035 D-2: Hyprland's config errors, as one notice per new set (its red bar is off, config/hypr/grassfield/core.lua).
    // The lines are the details (no terminal: decision 3-6); the notice goes once they are gone.
    ConfigErrors {
        property string noticeKey: ""
        onAppeared: (lines, more) => {
            if (noticeKey !== "")
                Notifications.clear(noticeKey);
            // Singular/plural pair (the catalogs carry no numerus forms).
            const rest = more === 1 ? qsTr("and 1 more") : qsTr("and %1 more").arg(more);
            const body = more > 0 ? lines.concat([rest]) : lines;
            noticeKey = Notifications.postInternal(qsTr("Some settings could not be applied"), body.join("\n"));
        }
        onCleared: {
            if (noticeKey !== "")
                Notifications.clear(noticeKey);
            noticeKey = "";
        }
    }

    Connections {
        target: SettingsApp

        function onMissing(): void {
            Notifications.postInternal(qsTr("Grassfield Settings is not installed"), qsTr("Install the grassfield-desktop package to open Settings."));
        }
    }

    Connections {
        target: GlanceApp

        function onMissing(): void {
            Notifications.postInternal(qsTr("Glance is not available"), qsTr("Install the grassfield-desktop package to preview files with Space."));
        }
    }

    Connections {
        target: Capabilities

        // No reply for helloAbsentMs, an unload (empty capabilities event), or a plugin that loads after the notice.
        function onAbsentChanged(): void {
            root.syncDegradedNotice();
        }
    }

    Wallpaper {
        // The session lock owns the screen: a video wallpaper pauses (ADR-0016 section 5).
        locked: Lock.lockState !== "unlocked"
    }
    HotCorners {}
    DesktopIcons {}
    DesktopWidgets {}
    MenuBar {
        searchActive: searchSurface.open
        onSearchRequested: searchSurface.toggle()
    }
    Dock {
        onAppsRequested: appsSurface.toggle()
    }
    Overlay {}
    Stages {}
    Banners {}
    NotificationCenter {}
    OsdWindow {}
    Search {
        id: searchSurface
    }
    AuthAgent {
        id: authAgent
    }
    Idle {
        id: idle
        // Applications' org.freedesktop.ScreenSaver inhibitors, served by the menu bridge (GF-016).
        busInhibited: MenuBridge.screenSaverInhibited
    }
    // The screen saver (ADR-0032): the same inhibitors keep it off; its slideshow stops while the displays are off.
    Saver {
        id: saver
        busInhibited: MenuBridge.screenSaverInhibited
        displaysOff: idle.displayOff
    }
    Overview {
        id: overviewSurface
        // The session lock owns the screen and the keyboard: the overview closes and focuses nothing.
        locked: Lock.lockState !== "unlocked"
    }
    AppsController {
        id: appsSurface
    }
    Switcher {
        id: switcher
        // The session lock owns the screen and the keyboard: the switcher ends and does not start.
        locked: Lock.lockState !== "unlocked"
    }
    SwitcherWindow {
        controller: switcher
    }

    // Opening Overview, Apps, Search or the app switcher closes the others: the keyboard follows the visible top surface.
    ExclusiveSurfaces {
        surfaces: [
            {target: overviewSurface, close: () => overviewSurface.requestCloseForOther()},
            {target: appsSurface, close: () => appsSurface.hide()},
            {target: searchSurface, close: () => searchSurface.hide()},
            {target: switcher, close: () => switcher.cancel()}
        ]
    }

    // Referencing Capabilities instantiates it, which sends the plugin hello; referencing Lock
    // instantiates the session lock (IPC target "lock", crash-recovery restore); referencing RecentItems makes it listen to
    // every launch from the start (it would otherwise exist only once the Grassfield menu opened); referencing NotResponding
    // registers its IPC target "anr" for the hyprland-dialog stand-in (ADR-0035 D-3).
    Component.onCompleted: console.info("grassfield-shell: started, version", SystemInfo.grassfieldVersion, "plugin protocol", Capabilities.protocol, "lock", Lock.lockState, "recent items", RecentItems.max, "clipboard history", Clipboard.state, "not responding", NotResponding.marks.length)
}
