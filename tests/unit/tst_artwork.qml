import QtQuick
import QtTest
import Grassfield.Ui
import "../../ui/Grassfield/Ui/Artwork.js" as Artwork

// The Grassfield artworks (ADR-0040 step 2, ID-1): every palette from the `artwork.*` tokens, the default unchanged (the dark
// Evening is the picture the lock and the screen saver keep until step 4a), the seeded geometry the same at every start, and
// the component built for each artwork and variant.
TestCase {
    id: testCase
    name: "Artwork"
    width: 320
    height: 200
    visible: true
    when: windowShown

    readonly property var hex: /^#[0-9A-Fa-f]{6}$/

    function test_theDefaultIsTheArtworkAsItWas() {
        const p = Artwork.palette(Tokens, "grassfield", Artwork.DEFAULT_VARIANT);
        compare(p.sky, ["#0F2A3F", "#2F6F7E", "#E8C98B"]);
        compare(p.sun, "#FFF1C2");
        compare(p.sunAt, [0.68, 0.52, 0.25]);
        compare(p.hills, ["#3E7D5A", "#2E6B3F", "#1F4F2C", "#16391F"]);
        // The flat map the desktop reads: the tone's two colours first.
        compare(Artwork.flat(p).skyTop, "#0F2A3F");
        compare(Artwork.flat(p).skyMid, "#2F6F7E");
    }

    // The ground (ADR-0040 ID-2): the default artwork's is the session's static one (looknfeel.lua's background_color,
    // tests/unit/tst_sessionexit.qml), the mean of the sky's middle and the land's.
    function test_theGroundOfTheDefaultIsTheSessionGround() {
        const p = Artwork.palette(Tokens, "grassfield", Artwork.DEFAULT_VARIANT);
        compare(p.ground, Tokens.sessionGround.toUpperCase());
        compare(Artwork.palette(Tokens, "grassfield", "day.light").ground, "#98C6AE");
        compare(Artwork.palette(Tokens, "meadow", "light").ground, "#A5CD9B");
        compare(Artwork.palette(Tokens, "rows", "dark").ground, "#1F3D28");
        compare(Artwork.palette(Tokens, "ridgeline", "dark").ground, "#111D1E");
    }

    function test_unknownNamesReadAsTheDefault() {
        compare(Artwork.parse("nope", "x"), {artwork: "grassfield", phase: "evening", set: "dark"});
        compare(Artwork.parse("grassfield", "noon.light"), {artwork: "grassfield", phase: "evening", set: "dark"});
        compare(Artwork.parse("meadow", "light"), {artwork: "meadow", phase: "", set: "light"});
        compare(Artwork.parse("rows", "other"), {artwork: "rows", phase: "", set: "dark"});
    }

    function variants() {
        const out = [];
        for (const phase of ["dawn", "day", "evening", "night"])
            for (const set of ["light", "dark"])
                out.push(["grassfield", phase + "." + set]);
        for (const a of ["meadow", "rows", "ridgeline"])
            for (const set of ["light", "dark"])
                out.push([a, set]);
        return out;
    }

    function test_everyPaletteIsMadeOfTokenColours() {
        for (const [a, v] of variants()) {
            const p = Artwork.palette(Tokens, a, v);
            verify(p.colours.length >= 6, a + " " + v);
            for (const c of p.colours)
                verify(testCase.hex.test(c), a + " " + v + ": " + c);
            verify(testCase.hex.test(p.tone.top) && testCase.hex.test(p.tone.next), a + " " + v + ": the tone");
            verify(p.tone.at > 0 && p.tone.at <= 1);
            verify(testCase.hex.test(p.ground), a + " " + v + ": the ground");
            compare(p.stops.length, 3, a + " " + v);
        }
        // The two sets of the Grassfield artwork differ at every phase; the dark Evening is the only one kept from before.
        for (const phase of ["dawn", "day", "evening", "night"])
            verify(JSON.stringify(Artwork.palette(Tokens, "grassfield", phase + ".light").sky) !== JSON.stringify(Artwork.palette(Tokens, "grassfield", phase + ".dark").sky), phase);
    }

    function test_theGeometryIsSeeded() {
        const a = Artwork.meadowBlades(11), b = Artwork.meadowBlades(11);
        compare(JSON.stringify(a), JSON.stringify(b));
        compare(a.map(l => l.length), [26, 36, 46, 56]);
        verify(JSON.stringify(Artwork.meadowBlades(12)) !== JSON.stringify(a));
        const path = Artwork.meadowPath(a[0], 320, 200);
        compare(path.split("Z").length - 1, 26);
        const rows = Artwork.rowsPaths(6, 320, 200);
        compare(rows.length, 6);
        for (const r of rows)
            verify(/^M/.test(r) && /Z$/.test(r));
        compare(Artwork.ridgelinePaths(320, 200).length, 2);
        compare(Artwork.starCount(0, 0), 0);
        compare(Artwork.starCount(320, 200), 7);
        compare(Artwork.starCount(7680, 4320), 400);
        compare(JSON.stringify(Artwork.stars(7, 5)), JSON.stringify(Artwork.stars(7, 5)));
    }

    // ADR-0040 step 9 (IQ-W3 A): the moving variant's clouds and light.
    function test_theMovingVariant() {
        const c = Artwork.clouds(5, 4);
        compare(JSON.stringify(c), JSON.stringify(Artwork.clouds(5, 4)), "seeded");
        compare(c.length, 4);
        for (const k of c) {
            // Below the menu bar's strip (gate A2 holds as for the still picture) and above the hills.
            verify(k.y >= 0.1 && k.y + 2 * k.h <= 0.5, JSON.stringify(k));
            verify(k.speed > 0 && k.offset >= 0 && k.offset < 1);
            for (const ms of [0, 1000, 60000, 240000, 1e9]) {
                const x = Artwork.cloudX(k, ms, Tokens.wallpaperMovingCloudMs);
                verify(x >= -k.w && x <= 1, ms + ": " + x);
            }
        }
        // A cloud moves to the right, and comes back.
        verify(Artwork.cloudX(c[0], 1000, 240000) > Artwork.cloudX(c[0], 0, 240000) || Artwork.cloudX(c[0], 0, 240000) > 0.9);
        compare(Artwork.lightAt(0, 90000, 0.25), 1);
        fuzzyCompare(Artwork.lightAt(45000, 90000, 0.25), 0.75, 1e-9);
        fuzzyCompare(Artwork.lightAt(90000, 90000, 0.25), 1, 1e-9);
        // The clouds' colours are tokens, per set.
        compare(Artwork.palette(Tokens, "grassfield", "day.light").cloud, Tokens.artworkCloudLight);
        compare(Artwork.palette(Tokens, "grassfield", "night.dark").cloudAlpha, Tokens.wallpaperMovingCloudOpacityDark);
    }

    function test_itMovesOnlyWhilePlaying() {
        const item = createTemporaryObject(artComponent, testCase, {artwork: "grassfield", variant: "day.light", moving: true, playing: false});
        wait(Tokens.wallpaperMovingFrameMs * 3);
        compare(item.motionMs, 0, "paused: still");
        item.playing = true;
        tryVerify(() => item.motionMs >= 2 * Tokens.wallpaperMovingFrameMs, 2000);
        item.playing = false;
        const held = item.motionMs;
        wait(Tokens.wallpaperMovingFrameMs * 3);
        compare(item.motionMs, held, "paused again: it holds where it is");
        // Another artwork: nothing moves.
        const other = createTemporaryObject(artComponent, testCase, {artwork: "meadow", variant: "light", moving: true, playing: true});
        wait(Tokens.wallpaperMovingFrameMs * 3);
        compare(other.motionMs, 0);
    }

    // The clouds are one translucent layer (the integrator's review of e067f26f, NIT: two overlapping clouds showed each other's
    // edge): at the clouds' opacity, over their band only, at half the resolution; no layer without them.
    function test_theCloudsAreOneLayer() {
        function layers(item) {
            const out = [];
            (function walk(i) {
                for (const c of i.children) {
                    if (c.layer.enabled)
                        out.push(c);
                    walk(c);
                }
            })(item);
            return out;
        }
        const item = createTemporaryObject(artComponent, testCase, {artwork: "grassfield", variant: "day.light", moving: true});
        const one = layers(item);
        compare(one.length, 1);
        compare(one[0].opacity, Tokens.wallpaperMovingCloudOpacityLight);
        compare(one[0].y, item.height * 0.1);
        compare(one[0].height, item.height * 0.4);
        compare(one[0].layer.textureSize, Qt.size(Math.ceil(item.width / 2), Math.ceil(item.height * 0.4 / 2)));
        compare(layers(createTemporaryObject(artComponent, testCase, {artwork: "grassfield", variant: "day.light"})).length, 0);
    }

    Component {
        id: artComponent
        GrassfieldArtwork {
            width: 320
            height: 200
        }
    }

    function test_theComponentDrawsEachVariant() {
        for (const [a, v] of variants()) {
            const item = createTemporaryObject(artComponent, testCase, {artwork: a, variant: v});
            verify(item, a + " " + v);
            compare(item.artPalette.artwork, a);
            compare(item.art.skyTop, item.artPalette.tone.top);
        }
        // Without parameters: the default.
        const plain = createTemporaryObject(artComponent, testCase);
        compare(plain.artPalette.phase, "evening");
        compare(plain.artPalette.set, "dark");
        verify(plain.clip, "the blades, bands and glow stay inside the picture");
    }
}
