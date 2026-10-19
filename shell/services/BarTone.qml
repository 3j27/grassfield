pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import "BarToneLogic.js" as Logic

// Adaptive menu bar foreground, one tone per output (macOS model: over a transparent bar the text and glyphs follow what is
// behind them). The wallpaper (shell/desktop/Wallpaper.qml: the artwork, or an image) reports the luminance of the strip under
// the bar when the wallpaper or the output changes; the bar (shell/menubar/MenuBar.qml) reads the tone. "light" is the white
// foreground (dark wallpaper, also the answer before anything is measured), "dark" the black one.
Singleton {
    id: root

    // {output name: "light" | "dark"} and {output name: relative luminance}; replaced as a whole on every report.
    property var tones: ({})
    property var luminances: ({})

    // Test hook: qs ipc call bartone status -> JSON {output: {tone, luminance}} (read-only).
    IpcHandler {
        target: "bartone"

        function status(): string {
            const out = {};
            for (const name of Object.keys(root.tones))
                out[name] = {tone: root.tones[name], luminance: root.luminances[name]};
            return JSON.stringify(out);
        }
    }

    // Relative luminance of the wallpaper under the Dock shelf, per output (reported by the wallpaper like the bar strip).
    // The running dots of the Dock take the tone that keeps 3:1 or more against the shelf (see dotToneFor).
    property var dockWallLuminances: ({})

    function reportDock(output: string, lum: real): void {
        const next = Object.assign({}, dockWallLuminances);
        next[output] = lum;
        dockWallLuminances = next;
    }

    // "light" (white dot) or "dark" (black dot) for the shelf of `output`: its relative luminance is the tint (`tint`, at
    // `alpha`) over the wallpaper measured under it (a dark wallpaper until measured).
    function dotToneFor(output: string, tint: color, alpha: real): string {
        const wall = dockWallLuminances[output] !== undefined ? dockWallLuminances[output] : 0;
        return Logic.dotTone(Logic.shelfLuminance(wall, {r: tint.r, g: tint.g, b: tint.b}, alpha), Tokens.dockIndicatorDarkAbove);
    }

    // Relative luminance of a QML colour.
    function colorLuminance(c: color): real {
        return Logic.luminance(c.r, c.g, c.b);
    }

    // Luminance of the rows of RGBA bytes from `from` to the end of a `width` x height grab, central `span` of the columns.
    function dockLuminance(bytes: var, width: int, from: int, rows: int, span: real): real {
        return Logic.regionLuminance(bytes, width, from, rows, span);
    }

    function toneOf(output: string): string {
        return tones[output] || "light";
    }

    function report(output: string, lum: real): void {
        const next = Object.assign({}, luminances);
        next[output] = lum;
        luminances = next;
        tones = Logic.update(tones, output, lum, Tokens.menubarToneLightBelow, Tokens.menubarToneDarkAbove);
    }

    // Luminance of a strip from RGBA bytes (a downscaled grab, Canvas getImageData); report() it once the paint is over.
    function pixelsLuminance(bytes: var): real {
        return Logic.meanLuminance(bytes);
    }

    // Luminance of a strip of a vertical gradient from colour `top` towards colour `next` (QML colours), the strip reaching
    // the fraction `reach` of the way (the procedural artwork: its top is a known gradient, nothing is sampled).
    function reportGradient(output: string, top: color, next: color, reach: real): void {
        report(output, Logic.stripOfGradient({r: top.r, g: top.g, b: top.b}, {r: next.r, g: next.g, b: next.b}, reach));
    }
}
