import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/dock/Magnify.js" as Magnify
import "../../shell/dock/AutoHide.js" as AutoHide

// Dock feel, headless (offscreen, no compositor): drives the pure Dock logic (Magnify.js, AutoHide.js) the way Dock.qml
// does, in fixed time steps, with the real tokens. tests/shell/dockfeel_mutants.sh runs this file against deliberately broken
// copies of the two scripts: every assertion here must fail on at least one of them.
TestCase {
    name: "DockFeel"

    readonly property real iconSize: Tokens.dockIconSize
    readonly property real spacing: Tokens.dockSpacing
    readonly property real pitch: iconSize + spacing
    readonly property real maxScale: 1.6
    readonly property real radius: Tokens.dockMagnificationRadius
    readonly property real tau: Tokens.dockMagnificationTau
    readonly property real maxDt: Tokens.dockMagnificationMaxDt
    readonly property real frame: 16
    // Eight apps, a separator, two more tiles: the shape of a real Dock.
    readonly property var widths: [48, 48, 48, 48, 48, 48, 48, 48, 9, 48, 48]
    readonly property var fixed: [false, false, false, false, false, false, false, false, true, false, false]
    readonly property real shelfCentre: 600
    readonly property real baseLeft: shelfCentre - Magnify.totalWidth(widths, spacing) / 2
    readonly property var baseCenters: Magnify.centersFor(widths, spacing, baseLeft)

    function targetsFor(pointerX) {
        return Magnify.slotScales(baseCenters, widths, spacing, fixed, pointerX, pitch, maxScale, radius);
    }

    // Left edges of the tiles for the given scales, the shelf kept centred as the Dock does.
    function layoutFor(scalesList) {
        const scaled = widths.map((w, i) => w * scalesList[i]);
        const left = shelfCentre - Magnify.totalWidth(scaled, spacing) / 2;
        return Magnify.lefts(widths, scalesList, spacing, left);
    }

    // ---- magnification ----

    function test_noJumpAtSlotBoundaries() {
        // A pointer sweep in 0.5 px steps: no tile moves by more than the pointer does (the shelf follows the integral of
        // the curve), neighbours never overlap and keep their spacing.
        const from = baseLeft - 80;
        const to = baseLeft + Magnify.totalWidth(widths, spacing) + 80;
        let prev = null;
        let worst = 0;
        for (let p = from; p <= to; p += 0.5) {
            const s = targetsFor(p);
            const x = layoutFor(s);
            for (let i = 0; i + 1 < x.length; i++) {
                const gap = x[i + 1] - (x[i] + widths[i] * s[i]);
                verify(Math.abs(gap - spacing) < 1e-6, "tile " + i + " gap " + gap + " at pointer " + p);
            }
            if (prev) {
                for (let i = 0; i < x.length; i++)
                    worst = Math.max(worst, Math.abs(x[i] - prev[i]));
            }
            prev = x;
        }
        verify(worst <= 0.5 * 1.0 + 1e-6, "a tile moved " + worst + " px for a 0.5 px pointer step");
    }

    function test_noJumpAcrossEachBoundary() {
        // Straddling the boundary between two slots (their shared edge), the scales and positions are continuous.
        for (let i = 0; i + 1 < widths.length; i++) {
            const edge = (baseCenters[i] + widths[i] / 2 + baseCenters[i + 1] - widths[i + 1] / 2) / 2;
            const a = layoutFor(targetsFor(edge - 0.01));
            const b = layoutFor(targetsFor(edge + 0.01));
            for (let k = 0; k < a.length; k++)
                verify(Math.abs(a[k] - b[k]) < 0.02, "tile " + k + " jumped " + Math.abs(a[k] - b[k]) + " px at boundary " + i);
        }
    }

    function test_displacementIsTheIntegralOfTheCurve() {
        // The slots tile the line, so the extra width of the whole row equals the integral of the curve (both sides of the
        // pointer, 0.5 reach each, times max - 1): neighbours are displaced by that integral, not by a sampled curve.
        const s = targetsFor(baseCenters[3]);
        let extra = 0;
        for (let i = 0; i < s.length; i++)
            extra += (widths[i] + spacing) * (s[i] - 1);
        fuzzyCompare(extra, (maxScale - 1) * radius * pitch, 0.05);
        // The hovered tile takes the mean of the curve over its own slot (numeric check, independent of the closed form).
        let sum = 0;
        const n = 4000;
        const half = pitch / 2;
        for (let k = 0; k < n; k++)
            sum += Magnify.scale(-half + pitch * (k + 0.5) / n, pitch, maxScale, radius);
        fuzzyCompare(s[3], sum / n, 1e-6);
        verify(s[3] < maxScale - 1e-4, "the hovered tile is at the point value " + s[3]);
    }

    function test_profileIsSmootherstep() {
        // Distinct from the old cosine at a quarter of the reach, and flat at the reach.
        const reach = radius * pitch;
        const t = 0.25;
        const expected = 1 + (maxScale - 1) * (1 - (10 * t * t * t - 15 * t * t * t * t + 6 * t * t * t * t * t));
        fuzzyCompare(Magnify.scale(t * reach, pitch, maxScale, radius), expected, 1e-9);
        verify(Magnify.scale(reach - 3, pitch, maxScale, radius) - 1 < 1e-4);
    }

    // Runs the smoothing at `dt` ms per step from `start` to `target` scales; returns the frames.
    function run(startScales, targetFn, durationMs, dt, tauMs) {
        const frames = [];
        let cur = startScales;
        for (let t = 0; t <= durationMs + 1e-9; t += dt) {
            cur = Magnify.step(cur, targetFn(t), dt, tauMs, maxDt);
            frames.push({
                t: t + dt,
                scales: cur
            });
        }
        return frames;
    }

    function timeToFraction(dt, fraction) {
        const hovered = 4;
        const target = targetsFor(baseCenters[hovered]);
        const ones = widths.map(() => 1);
        const frames = run(ones, () => target, 600, dt, tau);
        for (let i = 0; i < frames.length; i++) {
            if ((frames[i].scales[hovered] - 1) / (target[hovered] - 1) >= fraction)
                return frames[i].t;
        }
        return Infinity;
    }

    function test_settlesWithin220ms() {
        const t90 = timeToFraction(frame, 0.9);
        verify(t90 <= 220, "90% reached at " + t90 + " ms");
        // ... and it is smoothed: the first frame is not already there.
        verify(timeToFraction(frame, 0.99) > frame);
        verify(timeToFraction(frame, 0.9) > frame);
    }

    function test_frameRateIndependent() {
        const a = timeToFraction(8, 0.9);
        const b = timeToFraction(16, 0.9);
        const c = timeToFraction(33, 0.9);
        verify(Math.abs(a - b) <= 40 && Math.abs(c - b) <= 40, "90% at " + a + " / " + b + " / " + c + " ms for 8 / 16 / 33 ms frames");
    }

    function test_stalledFrameIsCapped() {
        // One 1 s frame must not jump to the target: it counts as at most maxDt.
        const ones = widths.map(() => 1);
        const target = targetsFor(baseCenters[4]);
        const next = Magnify.step(ones, target, 1000, tau, maxDt);
        const limit = 1 - Math.exp(-maxDt / tau);
        verify((next[4] - 1) / (target[4] - 1) <= limit + 1e-9, "a 1 s frame advanced " + (next[4] - 1) / (target[4] - 1));
    }

    function test_noScaleReversalDuringSweep() {
        // A monotonic pointer sweep (400 px/s, one stalled frame in the middle): every tile's scale rises, then falls: one
        // peak, no wobble.
        const ones = widths.map(() => 1);
        const series = ones.map(() => []);
        let cur = ones;
        let p = baseLeft - 120;
        const end = baseLeft + Magnify.totalWidth(widths, spacing) + 120;
        let n = 0;
        while (p < end) {
            const dt = n === 40 ? 120 : frame;
            cur = Magnify.step(cur, targetsFor(p), dt, tau, maxDt);
            for (let i = 0; i < cur.length; i++)
                series[i].push(cur[i]);
            p += 400 * dt / 1000;
            n++;
        }
        for (let i = 0; i < series.length; i++) {
            if (fixed[i])
                continue;
            let dir = 0;
            let turns = 0;
            for (let k = 1; k < series[i].length; k++) {
                const d = series[i][k] - series[i][k - 1];
                if (Math.abs(d) < 1e-7)
                    continue;
                const sign = d > 0 ? 1 : -1;
                if (dir !== 0 && sign !== dir)
                    turns++;
                dir = sign;
            }
            verify(turns <= 1, "tile " + i + " reversed " + turns + " times");
        }
    }

    function test_settlesFullyWhenThePointerLeaves() {
        const ones = widths.map(() => 1);
        let cur = Magnify.step(ones, targetsFor(baseCenters[3]), 500, tau, maxDt);
        // The pointer has been on the Dock long enough to be at the target; now it leaves (targets all 1).
        for (let k = 0; k < 40; k++)
            cur = Magnify.step(cur, targetsFor(baseCenters[3]), frame, tau, maxDt);
        verify(cur[3] > 1.5);
        const frames = run(cur, () => ones, 600, frame, tau);
        const last = frames[frames.length - 1].scales;
        for (let i = 0; i < last.length; i++)
            verify(Math.abs(last[i] - 1) < 5e-4, "tile " + i + " stuck at " + last[i]);
        const x = layoutFor(last);
        const base = layoutFor(ones);
        for (let i = 0; i < x.length; i++)
            verify(Math.abs(x[i] - base[i]) < 0.05, "tile " + i + " is " + Math.abs(x[i] - base[i]) + " px off its slot");
    }

    // ---- auto-hide ----

    readonly property var timing: ({
            hideGrace: Tokens.dockHideGrace,
            hideDuration: Tokens.dockHideDuration,
            revealDwell: Tokens.dockRevealDwell,
            revealDuration: Tokens.dockRevealDuration
        })
    readonly property var none: ({})
    readonly property var kinds: ["pointer", "drag", "popup", "hold", "keyboard", "forced"]

    function only(kind) {
        const o = {};
        o[kind] = true;
        return o;
    }

    function advance(m, inh, ms, enabled) {
        const times = Math.round(ms / frame);
        for (let i = 0; i < times; i++)
            m = AutoHide.step(m, inh, enabled === undefined ? true : enabled, timing, frame);
        return m;
    }

    function test_neverHidesWhileInhibited() {
        for (let k = 0; k < kinds.length; k++) {
            let m = AutoHide.create();
            for (let t = 0; t < 5000; t += frame) {
                m = AutoHide.step(m, only(kinds[k]), true, timing, frame);
                verify(m.state === "shown" && m.visible === 1, kinds[k] + " inhibitor: " + m.state + " at " + t + " ms");
            }
        }
    }

    function test_inhibitorStopsAHideInProgress() {
        for (let k = 0; k < kinds.length; k++) {
            let m = advance(AutoHide.create(), none, timing.hideGrace + timing.hideDuration / 2);
            verify(m.state === "hiding" && m.visible < 1 && m.visible > 0, "setup: " + m.state);
            const at = m.visible;
            for (let t = 0; t < 2000; t += frame) {
                const before = m.visible;
                m = AutoHide.step(m, only(kinds[k]), true, timing, frame);
                verify(m.visible >= before - 1e-9, kinds[k] + ": the shelf kept sliding away");
                verify(m.state !== "hidden", kinds[k] + ": hid while inhibited");
            }
            verify(m.state === "shown" && m.visible === 1, kinds[k] + ": " + m.state);
            verify(at < 1);
        }
    }

    function test_hidingIsDelayedThenSlides() {
        let m = AutoHide.create();
        m = advance(m, none, timing.hideGrace - 2 * frame);
        compare(m.state, "shown");
        m = advance(m, none, 3 * frame);
        compare(m.state, "hiding");
        m = advance(m, none, timing.hideDuration + 2 * frame);
        compare(m.state, "hidden");
        compare(m.visible, 0);
    }

    function test_graceRestartsWhenInhibitorLeaves() {
        let m = advance(AutoHide.create(), none, timing.hideGrace - 2 * frame);
        m = advance(m, only("pointer"), 3 * frame);
        m = advance(m, none, timing.hideGrace - 2 * frame);
        compare(m.state, "shown");
    }

    function test_hiddenRevealsOnlyAfterTheEdgeDwell() {
        let m = advance(AutoHide.create(), none, timing.hideGrace + timing.hideDuration + 5 * frame);
        compare(m.state, "hidden");
        // The pointer alone at the edge strip: nothing before the dwell, then the slide in.
        m = advance(m, only("pointer"), timing.revealDwell - 2 * frame);
        compare(m.state, "hidden");
        m = advance(m, none, 3 * frame);
        compare(m.state, "hidden");
        m = advance(m, only("pointer"), timing.revealDwell + 2 * frame);
        compare(m.state, "revealing");
        m = advance(m, only("pointer"), timing.revealDuration + 2 * frame);
        compare(m.state, "shown");
        compare(m.visible, 1);
    }

    function test_otherInhibitorsRevealAtOnce() {
        for (let k = 1; k < kinds.length; k++) {
            let m = advance(AutoHide.create(), none, timing.hideGrace + timing.hideDuration + 5 * frame);
            compare(m.state, "hidden");
            m = advance(m, only(kinds[k]), frame);
            compare(m.state, "revealing", kinds[k]);
            m = advance(m, only(kinds[k]), timing.revealDuration + 2 * frame);
            compare(m.state, "shown", kinds[k]);
        }
    }

    function test_pointerReturnReversesWithoutJump() {
        let m = advance(AutoHide.create(), none, timing.hideGrace + timing.hideDuration / 2);
        const before = m.visible;
        const after = AutoHide.step(m, only("pointer"), true, timing, frame);
        compare(after.state, "revealing");
        verify(Math.abs(after.visible - before) < 1e-9, "the position jumped on reversal");
        const next = AutoHide.step(after, only("pointer"), true, timing, frame);
        verify(next.visible - after.visible <= frame / timing.revealDuration + 1e-9);
    }

    function test_positionNeverJumps() {
        let m = AutoHide.create();
        const script = [[none, 1200], [only("pointer"), 700], [none, 1200], [only("popup"), 700], [none, 1200]];
        for (let s = 0; s < script.length; s++) {
            for (let t = 0; t < script[s][1]; t += frame) {
                const before = m.visible;
                m = AutoHide.step(m, script[s][0], true, timing, frame);
                verify(Math.abs(m.visible - before) <= frame / Math.min(timing.hideDuration, timing.revealDuration) + 1e-9);
            }
        }
    }

    function test_disabledIsAlwaysShown() {
        let m = advance(AutoHide.create(), none, timing.hideGrace + timing.hideDuration + 5 * frame);
        compare(m.state, "hidden");
        m = AutoHide.step(m, none, false, timing, frame);
        compare(m.state, "shown");
        compare(m.visible, 1);
        verify(!AutoHide.active(m, none, false));
    }

    function test_clockStopsOnlyWhenNothingCanChange() {
        const shown = AutoHide.create();
        verify(AutoHide.active(shown, none, true));
        verify(!AutoHide.active(shown, only("pointer"), true));
        const hidden = advance(shown, none, timing.hideGrace + timing.hideDuration + 5 * frame);
        verify(!AutoHide.active(hidden, none, true));
        verify(AutoHide.active(hidden, only("pointer"), true));
    }
}
