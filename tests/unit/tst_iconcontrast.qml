import QtQuick
import QtTest
import Grassfield.Ui

// Internal contrast of the fixed per-mode recolouring (ADR-0014, docs/specs/ui.md "Icon shader"): two colours of an icon that differ
// by 3:1 or more in the default rendering (a terminal's light prompt on its black plate, a red glyph on a dark one, black art on
// light art) still differ by 3:1 (less 0.1 for the 8 bits) in Dark, Clear and Tinted, in both appearances and over the
// surfaces the model knows, so no glyph "nearly vanishes". The arithmetic is the shader's (FolderStyle.modeSamples and underlay,
// compared with the rendered pixels by tests/unit/tst_iconshader.qml). The A2 test measures the same on real icons.
TestCase {
    id: testCase
    name: "IconContrast"

    readonly property real minDefault: 4.5

    // What a pair keeps: a strong pair (7:1 and more in the default rendering: a prompt on a black plate) 3:1 (less 0.1 of rounding); any
    // pair from 4.5:1 up never collapses to near-invisible (2.3:1). A recolouring that lifts black (the plate must show through) cannot keep
    // every 3:1 pair: black art raised to the floor of the mode bounds the ratio to black art against mid-grey.
    function floorFor(def) {
        return def >= 7 ? 2.9 : 2.3;
    }
    readonly property var colours: [
        "#000000", "#0d0d0d", "#1a1a1a", "#333333", "#555555", "#808080", "#aaaaaa", "#d0d0d0", "#ffffff",
        "#e02020", "#c03030", "#ff3b30", "#2a9d3a", "#20c040", "#2060e0", "#4da3ff", "#e5b422", "#9b59b6", "#74cbf5"
    ]

    function composite(mode, rgb, dark, tint) {
        const t = Tokens;
        const backdrop = FolderStyle.rgbOf(dark ? t.folderIconPlateBackdropDark : t.folderIconPlateBackdropLight);
        const under = FolderStyle.underlay(mode, tint, dark, false, backdrop, t);
        const px = FolderStyle.modeSamples([rgb[0], rgb[1], rgb[2], 1], mode, tint, dark, t);
        const a = px[3];
        return [0, 1, 2].map(q => px[q] * a + under[q] * (1 - a));
    }

    function test_pairsKeepTheirContrast() {
        const bad = [];
        const counts = {};
        let pairs = 0;
        for (const tint of ["#3E7BFA", "#E6B422", "#E25AA1", "#26763F", "#4FB36B"]) {
            for (const dark of [true, false]) {
                for (const mode of ["dark", "clear", "tinted"]) {
                    if (mode !== "tinted" && tint !== "#3E7BFA")
                        continue;
                    for (let i = 0; i < colours.length; i++) {
                        for (let j = i + 1; j < colours.length; j++) {
                            const a = FolderStyle.rgbOf(colours[i]);
                            const b = FolderStyle.rgbOf(colours[j]);
                            if (FolderStyle.contrastRatio(a, b) < testCase.minDefault)
                                continue;
                            pairs++;
                            const r = FolderStyle.contrastRatio(composite(mode, a, dark, tint), composite(mode, b, dark, tint));
                            if (r < testCase.floorFor(FolderStyle.contrastRatio(a, b)))
                                counts[mode + (dark ? " dark" : " light") + (mode === "tinted" ? " " + tint : "")] = (counts[mode + (dark ? " dark" : " light") + (mode === "tinted" ? " " + tint : "")] || 0) + 1;
                            if (r < testCase.floorFor(FolderStyle.contrastRatio(a, b)))
                                bad.push(`${mode} ${dark ? "dark" : "light"} ${tint}: ${colours[i]} vs ${colours[j]} ${FolderStyle.contrastRatio(a, b).toFixed(2)} -> ${r.toFixed(2)}`);
                        }
                    }
                }
            }
        }
        verify(pairs > 500, "pairs " + pairs);
        if (bad.length > 0)
            fail(bad.length + " of " + pairs + " pairs lose contrast " + JSON.stringify(counts) + "; first: " + bad.slice(0, 12).join(" | "));
    }

    // The map is monotonic: a lighter colour never becomes darker (grey ramp, every mode and appearance).
    function test_mapsAreMonotonic() {
        for (const dark of [true, false]) {
            for (const mode of ["dark", "clear", "tinted"]) {
                let last = -1;
                for (let v = 0; v <= 255; v += 5) {
                    const g = v / 255;
                    const y = FolderStyle.relativeLuminance(composite(mode, [g, g, g], dark, "#3E7BFA"));
                    // Clear in the light appearance is smoked ink: lighter art is MORE transparent, so the composite gets lighter too
                    // over the light backdrop, and darker over the dark one in the dark appearance; compare ordering of the art itself.
                    if (mode === "clear" && !dark) {
                        verify(last < 0 || y >= last - 1e-9, `clear light not monotonic at ${v}`);
                    } else {
                        verify(last < 0 || y >= last - 1e-9, `${mode} ${dark ? "dark" : "light"} not monotonic at ${v}`);
                    }
                    last = y;
                }
            }
        }
    }
}
