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
            compare(item.palette.artwork, a);
            compare(item.art.skyTop, item.palette.tone.top);
        }
        // Without parameters: the default.
        const plain = createTemporaryObject(artComponent, testCase);
        compare(plain.palette.phase, "evening");
        compare(plain.palette.set, "dark");
        verify(plain.clip, "the blades, bands and glow stay inside the picture");
    }
}
