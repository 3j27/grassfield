pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib

// Dev-only hooks for deterministic screenshots and the contrast measurement (tests/visual).
//
// Fixtures: active only with GRASSFIELD_DEV=1 AND GRASSFIELD_VISUAL_FIXTURES=1 AND GRASSFIELD_SESSION != 1. Connectivity, Bluetooth, the
// user name and the battery then report fixed fake values instead of the owner's machine. Actions stay behind
// their dev guards. Inert otherwise.
//
// Glyph mask: `qs ipc call visual glyphs <normal|hidden|white|black>` (GRASSFIELD_DEV=1 only, else "refused")
// renders every text and icon colour transparent, white or black (Appearance.devGlyphMode). The contrast run
// captures a surface in all four modes: hidden is the exact backdrop, white and black give the exact glyph
// coverage per pixel whatever the backdrop (tests/visual/contrast.py).
//
// Wallpaper override: see wallpaperFile (dev only).
Singleton {
    id: root

    // Never in a packaged session: GRASSFIELD_SESSION=1 (config/hypr/session.lua) turns every hook off, fixtures and
    // glyph mask alike, even when GRASSFIELD_DEV=1 leaks into the environment. The nested dev session never sets it (shell-run.sh
    // leaves it alone; only the packaged session config sets it). The shell's one dev rule (ADR-0019: qs.lib Mode, defined
    // by shell/lib/RunMode.js): every IPC test hook outside the security modules checks this property or Mode.dev
    // (docs/specs/security.md "IPC surface").
    readonly property bool dev: Mode.dev
    readonly property bool active: Mode.fixtures
    readonly property string network: "Grassfield"
    readonly property string user: "grassfield"

    property string glyphMode: ""

    // Wallpaper override of the contrast run (tests/visual/contrast.sh): validated and set by the desktop wallpaper
    // (shell/desktop/Wallpaper.qml: GRASSFIELD_WALLPAPER_FILE at start, `qs ipc call wallpaper set <path>`), drawn by the
    // desktop wallpaper and, blurred, by the lock screen backdrop (shell/security/lock/LockView.qml), so that both are
    // measured over the same worst-case images. wallpaperFile is always "" outside dev, whatever wallpaperOverride holds.
    property string wallpaperOverride: Mode.devValue("WALLPAPER_FILE")
    readonly property string wallpaperFile: dev ? wallpaperOverride : ""

    Binding {
        target: Appearance
        property: "devGlyphMode"
        value: root.dev ? root.glyphMode : ""
    }

    IpcHandler {
        target: "visual"

        function glyphs(mode: string): string {
            if (!root.dev)
                return "refused";
            if (["normal", "hidden", "white", "black"].indexOf(mode) < 0)
                return "refused: mode must be normal, hidden, white or black";
            root.glyphMode = mode === "normal" ? "" : mode;
            return "ok";
        }
    }
}
