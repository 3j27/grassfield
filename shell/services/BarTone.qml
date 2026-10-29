pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
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
    // {output name: true} when neither tone reaches 4.5:1 over that output's strip: the bar shows its frosted band there
    // (ADR-0016 section 7, the macOS "show menu bar background" switched on automatically). Only a measured picture can.
    property var assists: ({})
    // {output name: {white, black}} worst-case contrast of each tone, for the status hook and the journal.
    property var contrasts: ({})

    // Test hook: qs ipc call bartone status -> JSON {output: {tone, luminance, assist, white, black}} (read-only; dev
    // session only, SEC-04).
    IpcHandler {
        target: "bartone"

        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            const out = {};
            for (const name of Object.keys(root.tones))
                out[name] = {tone: root.tones[name], luminance: root.luminances[name], assist: root.assists[name] === true, white: root.contrasts[name] ? root.contrasts[name].white : null, black: root.contrasts[name] ? root.contrasts[name].black : null};
            return JSON.stringify(out);
        }
    }

    function toneOf(output: string): string {
        return tones[output] || "light";
    }

    function assistOf(output: string): bool {
        return assists[output] === true;
    }

    // A mean luminance (the artwork, a colour, the dev image override): the tone by thresholds, never the band.
    function report(output: string, lum: real): void {
        const next = Object.assign({}, luminances);
        next[output] = lum;
        luminances = next;
        tones = Logic.update(tones, output, lum, Tokens.menubarToneLightBelow, Tokens.menubarToneDarkAbove);
        setAssist(output, false);
    }

    function setAssist(output: string, on: bool): void {
        if ((assists[output] === true) === on)
            return;
        const next = Object.assign({}, assists);
        next[output] = on;
        assists = next;
    }

    // Luminance of a strip from RGBA bytes (a downscaled grab, Canvas getImageData); report() it once the paint is over.
    function pixelsLuminance(bytes: var): real {
        return Logic.meanLuminance(bytes);
    }

    // The strip statistics the wallpaper helper wrote next to a prepared picture (ADR-0016: {all: {mean, p5, p95}, ...}).
    // The tone is the one with the better worst case over the strip's 5th and 95th percentile; with neither reaching 4.5:1
    // the output gets the frosted band. The decision is logged (the owner reads it in the journal during a live session).
    function reportStrip(output: string, strip: var): void {
        if (!strip || !strip.all || typeof strip.all.p5 !== "number" || typeof strip.all.p95 !== "number")
            return;
        const r = Logic.stripTone(strip.all.p5, strip.all.p95, tones[output] || "", Tokens.menubarToneNeededContrast, Tokens.menubarToneMargin);
        const lums = Object.assign({}, luminances);
        lums[output] = strip.all.mean;
        luminances = lums;
        const t = Object.assign({}, tones);
        t[output] = r.tone;
        tones = t;
        const c = Object.assign({}, contrasts);
        c[output] = {white: r.white, black: r.black};
        contrasts = c;
        setAssist(output, r.assist);
        console.info("wallpaper tone=" + r.tone + " worst=" + r.best.toFixed(2) + " assist=" + r.assist + " output=" + output);
    }

    function toneSource(desc: var): string {
        return Logic.toneSource(desc);
    }

    // A picture or a video the helper gave no usable strip for: no band (macOS), the tone stays; the text keeps its faint shadow.
    function reportUnmeasured(output: string): void {
        setAssist(output, false);
        console.info("wallpaper tone unmeasured output=" + output);
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
