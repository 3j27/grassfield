import QtQuick
import QtTest
import Grassfield.Ui

// Gate A2 for the icon appearance modes (ADR-0014, docs/specs/ui.md "Icon shader"): every mode keeps an icon
// recognisable against the material behind it, in both appearances. The real pipeline draws real images (own SVG
// fixtures of tests/fixtures/icons, plus WhiteSur icons when .dev has them) through TintedIcon and the shader; the
// rendered pixels are measured.
//
// Pass rule, per icon, mode in dark/clear/tinted, appearance in light/dark, wallpaper in black/grey/white under the
// default material (the extremes bound the blurred backdrop):
//   floor(d) = 3 when the default rendering has d >= 3, else 0.9 * d (never more than 10 percent worse than default).
//   I (inside)  glyph-vs-plate contrast >= floor(default's), for icons whose default has a glyph (>= 2:1 inside).
//               Clear and Tinted are monochrome (a glyph differing from its plate only by hue loses that difference),
//               so their floor is min(2, 0.9 * default) instead of 3.
//   E (outside) the best of outline-vs-material, plate-vs-material and glyph-vs-material >= floor(default's): the icon
//               stays visible on the material by its edge or by its glyph.
// The plate is the median luminance of the ring 4 to 8 px inside the edge; the glyph is the 2nd or 98th percentile
// luminance of the core (8 px in), whichever is farther from the plate; the outline is the mean of the 2 px edge band.
// Known limits (documented in docs/specs/ui.md, "Icon shader"; still measured and logged, not failed):
//   - an icon without a plate whose glyph is near black (dark-glyph-no-plate): Clear and Tinted keep luminance detail
//     only, and in the dark range it is below 2:1 inside; Tinted also stays under 3:1 against a bright wallpaper's
//     dark material (no plate to lift).
//   - a logo without a plate in Tinted (light appearance): hue-only detail falls to about 1.8:1 inside.
//   - Nautilus-like icons whose plate is two halves (no single plate colour): Tinted in the dark appearance over the
//     brightest material reaches 2.5:1 by plate and rim.
// Contrast is the WCAG ratio of relative luminances. It needs a GPU scene graph (ShaderEffect does not run on the
// software renderer used by the offscreen platform): the test skips there; scripts/dev/test-icons.sh runs it in the
// nested session.
TestCase {
    id: testCase
    name: "IconShaderA2"
    visible: true
    when: windowShown
    width: 600
    height: 780

    readonly property int cell: 60
    readonly property int iconSize: 48
    readonly property int rowsPerGroup: 12
    readonly property string fixtureDir: Qt.resolvedUrl("../fixtures/icons/")
    readonly property string whitesurDir: Qt.resolvedUrl("../../.dev/share/icons/WhiteSur/apps/scalable/")
    readonly property var ownNames: ["white-plate-dark-glyph", "blue-plate-white-glyph", "graphite-plate-red-glyph", "white-plate-colour-glyph", "logo-no-plate", "dark-glyph-no-plate"]
    // Includes btop, Disk Usage Analyzer and white-plated icons (Chromium, Firefox, GIMP, Inkscape, Calendar, Notes).
    readonly property var whitesurNames: ["btop", "disk-usage-analyzer", "chromium", "firefox", "gimp", "inkscape", "org.gnome.Calendar", "accessories-text-editor", "org.gnome.Settings", "spotify", "vlc", "discord", "mpv", "obsidian", "foot", "org.gnome.Nautilus", "visual-studio-code"]
    readonly property var modes: ["default", "dark", "clear", "tinted"]
    readonly property var fixtures: {
        const out = [];
        for (const n of ownNames)
            out.push({name: n, url: fixtureDir + n + ".svg"});
        for (const n of whitesurNames)
            out.push({name: "whitesur:" + n, url: whitesurDir + n + ".svg"});
        return out;
    }

    property color panelColor: "#202024"
    property bool darkPass: true

    Item {
        id: board
        width: testCase.width
        height: testCase.height

        Repeater {
            id: slots
            model: testCase.fixtures.length * testCase.modes.length

            delegate: Rectangle {
                id: slot

                required property int index
                readonly property int fixture: Math.floor(slot.index / testCase.modes.length)
                readonly property int modeIndex: slot.index % testCase.modes.length
                property alias icon: tile

                x: (Math.floor(slot.fixture / testCase.rowsPerGroup) * testCase.modes.length + slot.modeIndex) * testCase.cell
                y: (slot.fixture % testCase.rowsPerGroup) * testCase.cell
                width: testCase.cell
                height: testCase.cell
                color: testCase.panelColor

                TintedIcon {
                    id: tile
                    anchors.centerIn: parent
                    size: testCase.iconSize
                    source: testCase.fixtures[slot.fixture].url
                    mode: testCase.modes[slot.modeIndex]
                    tint: "#3E7BFA"
                    darkAppearance: testCase.darkPass
                }
            }
        }
    }

    function channel(v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    function luminance(c) {
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }

    function ratio(a, b) {
        return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
    }

    function quantile(sorted, q) {
        return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
    }

    // The material colour over a flat wallpaper (sRGB compositing, as Qt does), default transparency.
    function materialOver(appearanceDark, wallpaper) {
        const tint = Qt.color((appearanceDark ? Tokens.colorDark : Tokens.colorLight).materialTint);
        const a = Appearance.tintAlpha(Tokens.materialDefaultTransparency);
        const w = Qt.color(wallpaper);
        return Qt.rgba(tint.r * a + w.r * (1 - a), tint.g * a + w.g * (1 - a), tint.b * a + w.b * (1 - a), 1);
    }

    // Contrast metrics of one rendered cell (a grabbed window image), see the pass rule above.
    function measure(img, slot, panel) {
        const half = testCase.iconSize / 2;
        const x0 = Math.round(slot.x + testCase.cell / 2 - half);
        const y0 = Math.round(slot.y + testCase.cell / 2 - half);
        const n = testCase.iconSize;
        const lp = luminance(panel);
        const lum = new Array(n * n);
        const mask = new Array(n * n);
        let count = 0;
        for (let y = 0; y < n; y++) {
            for (let x = 0; x < n; x++) {
                const c = img.pixel(x0 + x, y0 + y);
                const d = Math.max(Math.abs(c.r - panel.r), Math.abs(c.g - panel.g), Math.abs(c.b - panel.b));
                const m = d > 0.02;
                mask[y * n + x] = m;
                lum[y * n + x] = luminance(c);
                if (m)
                    count++;
            }
        }
        if (count < n * n / 20)
            return null;
        const at = (x, y) => x < 0 || y < 0 || x >= n || y >= n ? false : mask[y * n + x];
        const ring = [];
        const core = [];
        const band = [];
        for (let y = 0; y < n; y++) {
            for (let x = 0; x < n; x++) {
                if (!mask[y * n + x])
                    continue;
                const e2 = at(x - 2, y) && at(x + 2, y) && at(x, y - 2) && at(x, y + 2);
                const e4 = at(x - 4, y) && at(x + 4, y) && at(x, y - 4) && at(x, y + 4);
                const e8 = at(x - 8, y) && at(x + 8, y) && at(x, y - 8) && at(x, y + 8);
                if (!e2)
                    band.push(lum[y * n + x]);
                else if (e4 && !e8)
                    ring.push(lum[y * n + x]);
                if (e8)
                    core.push(lum[y * n + x]);
            }
        }
        if (core.length < 20 || ring.length < 20)
            return null;
        ring.sort((a, b) => a - b);
        core.sort((a, b) => a - b);
        // The plate is what lies just inside the edge; the glyph is the core's extreme farther from it.
        const body = quantile(ring, 0.5);
        const lo = quantile(core, 0.02);
        const hi = quantile(core, 0.98);
        const glyph = ratio(lo, body) >= ratio(hi, body) ? lo : hi;
        let outline = 0;
        for (const l of band)
            outline += l;
        outline = band.length > 0 ? outline / band.length : body;
        const plateOverPanel = ratio(body, lp);
        const outlineOverPanel = ratio(outline, lp);
        const glyphOverPanel = ratio(glyph, lp);
        return {
            inside: ratio(glyph, body),
            outside: Math.max(plateOverPanel, outlineOverPanel, glyphOverPanel),
            plateOverPanel: plateOverPanel,
            outlineOverPanel: outlineOverPanel,
            glyphOverPanel: glyphOverPanel
        };
    }

    readonly property var knownLimits: [
        "dark-glyph-no-plate clear I", "dark-glyph-no-plate tinted I", "dark-glyph-no-plate tinted E",
        "logo-no-plate tinted I", "whitesur:org.gnome.Nautilus tinted E"
    ]

    function test_iconsStayRecognisable() {
        if (board.GraphicsInfo.api === GraphicsInfo.Software)
            skip("needs a GPU scene graph (ShaderEffect does not run on the software renderer): scripts/dev/test-icons.sh");
        const failures = [];
        let measured = 0;
        const floorOf = v => v >= 3 ? 3 : 0.9 * v;
        const floorIn = (v, mode) => mode === "dark" ? floorOf(v) : Math.min(2, 0.9 * v);
        for (const dark of [true, false]) {
            for (const wallpaper of ["#000000", "#808080", "#ffffff"]) {
                testCase.darkPass = dark;
                testCase.panelColor = materialOver(dark, wallpaper);
                wait(700);
                waitForRendering(board);
                const img = grabImage(board);
                for (let f = 0; f < testCase.fixtures.length; f++) {
                    const cells = [];
                    for (let m = 0; m < testCase.modes.length; m++)
                        cells.push(slots.itemAt(f * testCase.modes.length + m));
                    if (cells[0] === undefined || cells[0].icon.status !== Image.Ready)
                        continue;
                    const base = measure(img, cells[0], testCase.panelColor);
                    if (base === null)
                        continue;
                    for (let m = 1; m < testCase.modes.length; m++) {
                        const r = measure(img, cells[m], testCase.panelColor);
                        const label = `${testCase.fixtures[f].name} ${testCase.modes[m]} ${dark ? "dark" : "light"} wallpaper ${wallpaper}`;
                        if (r === null) {
                            failures.push(label + ": nothing drawn");
                            continue;
                        }
                        measured++;
                        const line = `${label}: inside ${r.inside.toFixed(2)} (default ${base.inside.toFixed(2)}), outside ${r.outside.toFixed(2)} (default ${base.outside.toFixed(2)}; plate ${r.plateOverPanel.toFixed(2)} outline ${r.outlineOverPanel.toFixed(2)} glyph ${r.glyphOverPanel.toFixed(2)})`;
                        console.log("A2 " + line);
                        const key = testCase.fixtures[f].name + " " + testCase.modes[m] + " ";
                        if (base.inside >= 2 && r.inside < floorIn(base.inside, testCase.modes[m]) && testCase.knownLimits.indexOf(key + "I") < 0)
                            failures.push("I " + line);
                        if (r.outside < floorOf(base.outside) && testCase.knownLimits.indexOf(key + "E") < 0)
                            failures.push("E " + line);
                    }
                }
            }
        }
        verify(measured > 100, "measured " + measured + " icon renderings");
        if (failures.length > 0)
            fail(failures.length + " failures:\n" + failures.join("\n"));
    }
}
