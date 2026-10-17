pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// Dev-only hooks for deterministic screenshots and the contrast measurement (tests/visual).
//
// Fixtures: active only with GRASSFIELD_DEV=1 AND GRASSFIELD_VISUAL_FIXTURES=1. Connectivity, Bluetooth, the
// user name and the battery then report fixed fake values instead of the owner's machine. Actions stay behind
// their dev guards. Inert otherwise.
//
// Glyph mask: `qs ipc call visual glyphs <normal|hidden|white|black>` (GRASSFIELD_DEV=1 only, else "refused")
// renders every text and icon colour transparent, white or black (Appearance.devGlyphMode). The contrast run
// captures a surface in all four modes: hidden is the exact backdrop, white and black give the exact glyph
// coverage per pixel whatever the backdrop (tests/visual/contrast.py).
Singleton {
    id: root

    readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1"
    readonly property bool active: dev && Quickshell.env("GRASSFIELD_VISUAL_FIXTURES") === "1"
    readonly property string network: "Grassfield"
    readonly property string user: "grassfield"
    readonly property string hostname: "grassfield"

    property string glyphMode: ""

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
