pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform

// What lies behind the shell's glass on each output (ADR-0024 section 2 point 3, G-3; owner decision 2026-10-26: the adaptive
// tint first). An output is known only while it shows the bare desktop (no window on its active workspace,
// Compositor.bareOutputs) over a wallpaper whose luminance range is known (reported by shell/desktop/Wallpaper.qml).
// Appearance.backdrops gets {output: {lumMin, lumMax}} for those; every other glass takes the worst case (black to white).
Singleton {
    id: root

    // {output name: {lumMin, lumMax}} of the wallpaper on screen; no entry: unknown (a video, a picture prepared before the
    // helper wrote its image statistics, the dev image override).
    property var wallpapers: ({})

    readonly property var known: {
        const out = {};
        const bare = Compositor.bareOutputs;
        for (let i = 0; i < bare.length; i++) {
            if (root.wallpapers[bare[i]])
                out[bare[i]] = root.wallpapers[bare[i]];
        }
        return out;
    }

    function reportWallpaper(output: string, range: var): void {
        const next = Object.assign({}, root.wallpapers);
        if (range)
            next[output] = range;
        else
            delete next[output];
        root.wallpapers = next;
    }

    // The luminance range of a wallpaper display (WallpaperFeed's `display`): a colour exactly, the artwork over its whole
    // palette (sky, sun, hills: a conservative range), a still picture from the helper's 5th to 95th percentile of the whole
    // picture; null for a video or a picture without those statistics.
    function rangeOf(desc: var, art: var): var {
        if (!desc)
            return null;
        if (desc.kind === "color" && typeof desc.color === "string" && desc.color !== "") {
            const l = GlassTint.luminance(GlassTint.channels(desc.color));
            return {lumMin: l, lumMax: l};
        }
        if (desc.kind === "art" && art) {
            const lums = Object.keys(art).map(k => GlassTint.luminance(GlassTint.channels(String(art[k]))));
            return {lumMin: Math.min(...lums), lumMax: Math.max(...lums)};
        }
        if (desc.kind === "picture" && !desc.video && desc.image && typeof desc.image.p5 === "number" && typeof desc.image.p95 === "number")
            return {lumMin: desc.image.p5, lumMax: desc.image.p95};
        return null;
    }

    // Test hook: qs ipc call backdrop status -> JSON {wallpapers, bare, known} (read-only; dev session only, SEC-04).
    IpcHandler {
        target: "backdrop"

        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return JSON.stringify({wallpapers: root.wallpapers, bare: Compositor.bareOutputs, known: root.known});
        }
    }
}
