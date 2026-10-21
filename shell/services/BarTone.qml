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

    // The strip statistics the wallpaper helper wrote next to a prepared picture (ADR-0016: {all: {mean, p5, p95}, ...}).
    // The tone follows the mean, as for every other wallpaper; the percentile decision and the automatic band come with W6.
    function reportStrip(output: string, strip: var): void {
        if (strip && strip.all && typeof strip.all.mean === "number")
            report(output, strip.all.mean);
    }

    // A plain colour wallpaper (`color` source).
    function reportColor(output: string, color: color): void {
        report(output, Logic.luminance(color.r, color.g, color.b));
    }

    // Luminance of a strip of a vertical gradient from colour `top` towards colour `next` (QML colours), the strip reaching
    // the fraction `reach` of the way (the procedural artwork: its top is a known gradient, nothing is sampled).
    function reportGradient(output: string, top: color, next: color, reach: real): void {
        report(output, Logic.stripOfGradient({r: top.r, g: top.g, b: top.b}, {r: next.r, g: next.g, b: next.b}, reach));
    }
}
