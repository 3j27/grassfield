import QtQuick
import QtTest
import "../../shell/overview/Layout.js" as Layout

TestCase {
    name: "OverviewLayout"

    readonly property var area: ({x: 0, y: 100, w: 1920, h: 900})
    readonly property var opts: ({maxScale: 0.8, gap: 24})

    function grid(n, w, h, jitter) {
        const out = [];
        const cols = Math.ceil(Math.sqrt(n));
        for (let i = 0; i < n; i++) {
            const c = i % cols;
            const r = Math.floor(i / cols);
            out.push({id: "w" + i, x: 20 + c * (1920 / cols) * 0.9 + (jitter ? (i * 37) % 60 : 0), y: 30 + r * (1080 / cols) * 0.9, w: w, h: h});
        }
        return out;
    }

    function checkInvariants(input, res, label) {
        compare(res.rects.length, input.length, label + " count");
        verify(res.scale <= 0.8 + 1e-9, label + " scale <= max");
        verify(res.scale > 0, label + " scale > 0");
        for (let i = 0; i < res.rects.length; i++) {
            const r = res.rects[i];
            compare(r.id, input[i].id, label + " id order");
            verify(r.x >= area.x - 1e-6 && r.y >= area.y - 1e-6 && r.x + r.w <= area.x + area.w + 1e-6 && r.y + r.h <= area.y + area.h + 1e-6, label + " inside area " + JSON.stringify(r));
            for (let j = i + 1; j < res.rects.length; j++) {
                const o = res.rects[j];
                const sepX = Math.max(o.x - (r.x + r.w), r.x - (o.x + o.w));
                const sepY = Math.max(o.y - (r.y + r.h), r.y - (o.y + o.h));
                verify(Math.max(sepX, sepY) >= 24 - 1e-6, label + " gap " + i + "," + j + " = " + Math.max(sepX, sepY));
            }
        }
    }

    function test_empty() {
        compare(Layout.layout([], area, opts).rects.length, 0);
    }

    function test_single() {
        const input = [{id: "a", x: 100, y: 100, w: 800, h: 600}];
        const res = Layout.layout(input, area, opts);
        checkInvariants(input, res, "single");
        fuzzyCompare(res.scale, 0.8, 1e-9);
        fuzzyCompare(res.rects[0].w, 640, 1e-6);
    }

    function test_counts() {
        for (const n of [1, 2, 4, 9, 20]) {
            const input = grid(n, 700, 450, false);
            checkInvariants(input, Layout.layout(input, area, opts), "n=" + n);
        }
    }

    function test_overlappingStack() {
        const input = [];
        for (let i = 0; i < 9; i++)
            input.push({id: "s" + i, x: 200 + i * 40, y: 150 + i * 30, w: 900, h: 600});
        checkInvariants(input, Layout.layout(input, area, opts), "stack");
    }

    function test_identicalRectsUseTheArea() {
        // Four windows at the same place spread into a grid, not one thin column.
        const input = [];
        for (let i = 0; i < 4; i++)
            input.push({id: "t" + i, x: 610, y: 266, w: 700, h: 500});
        const res = Layout.layout(input, area, opts);
        checkInvariants(input, res, "identical");
        verify(res.scale > 0.5, "scale " + res.scale);
    }

    function test_oddAspectRatios() {
        const input = [
            {id: "wide", x: 0, y: 0, w: 1900, h: 80},
            {id: "tall", x: 50, y: 100, w: 90, h: 900},
            {id: "tiny", x: 700, y: 400, w: 40, h: 40},
            {id: "square", x: 900, y: 200, w: 500, h: 500},
            {id: "huge", x: 0, y: 0, w: 4000, h: 2000}
        ];
        checkInvariants(input, Layout.layout(input, area, opts), "odd");
    }

    function test_manyJittered() {
        const input = grid(20, 300, 200, true);
        checkInvariants(input, Layout.layout(input, area, opts), "20 jitter");
    }

    function test_relativeOrder() {
        const input = [{id: "l", x: 0, y: 0, w: 900, h: 700}, {id: "r", x: 1000, y: 0, w: 900, h: 700}];
        const res = Layout.layout(input, area, opts);
        checkInvariants(input, res, "pair");
        verify(res.rects[0].x < res.rects[1].x);
        verify(Math.abs(res.rects[0].y - res.rects[1].y) < 1e-6);
        const three = [{id: "a", x: 0, y: 0, w: 600, h: 800}, {id: "b", x: 650, y: 0, w: 600, h: 800}, {id: "c", x: 1300, y: 0, w: 600, h: 800}];
        const r3 = Layout.layout(three, area, opts);
        checkInvariants(three, r3, "three");
        verify(r3.rects[0].x < r3.rects[1].x && r3.rects[1].x < r3.rects[2].x);
    }

    function test_farApartOrderKept() {
        // Windows that are far apart vertically (over one window height) keep their vertical order.
        const input = grid(20, 700, 450, false);
        const res = Layout.layout(input, area, opts);
        for (let i = 0; i < 20; i++) {
            for (let j = 0; j < 20; j++) {
                if (input[j].y - input[i].y > 1.5 * 450)
                    verify(res.rects[i].y < res.rects[j].y, "vertical order " + i + "," + j);
            }
        }
    }

    function test_neighbor() {
        const rects = [{x: 0, y: 0, w: 10, h: 10}, {x: 20, y: 0, w: 10, h: 10}, {x: 0, y: 20, w: 10, h: 10}, {x: 20, y: 20, w: 10, h: 10}];
        compare(Layout.neighbor(rects, 0, "right"), 1);
        compare(Layout.neighbor(rects, 0, "down"), 2);
        compare(Layout.neighbor(rects, 3, "left"), 2);
        compare(Layout.neighbor(rects, 3, "up"), 1);
        compare(Layout.neighbor(rects, 0, "left"), -1);
        compare(Layout.neighbor(rects, 0, "up"), -1);
    }

    function test_timing() {
        const full = {x: 0, y: 100, w: 1920, h: 900};
        for (const c of [{n: 4, max: 40}, {n: 9, max: 40}, {n: 20, max: 40}]) {
            const input = grid(c.n, 700, 450, true);
            // Best of 20 against a bound ~3x the unloaded time (20 windows ~12 ms): under host load (parallel nested
            // sessions) even the best of 10 reached 21 ms; a non-linear or freezing layout still exceeds it every run.
            let best = Infinity;
            for (let k = 0; k < 20; k++) {
                const t0 = Date.now();
                Layout.layout(input, full, opts);
                best = Math.min(best, Date.now() - t0);
            }
            console.log("layout n=" + c.n + " min ms " + best);
            verify(best <= c.max, "n=" + c.n + " took " + best + " ms");
        }
        const stack = [];
        for (let i = 0; i < 20; i++)
            stack.push({id: "s" + i, x: 200 + i * 40, y: 150 + i * 30, w: 900, h: 600});
        let best = Infinity;
        for (let k = 0; k < 5; k++) {
            const t0 = Date.now();
            Layout.layout(stack, area, opts);
            best = Math.min(best, Date.now() - t0);
        }
        console.log("layout stack20 min ms " + best);
        verify(best <= 40, "stack20 took " + best + " ms");
        checkInvariants(stack, Layout.layout(stack, area, opts), "stack20");
    }

    function test_tinyAreaDoesNotHang() {
        const input = grid(9, 700, 450, false);
        const res = Layout.layout(input, {x: 0, y: 0, w: 1, h: 1}, opts);
        compare(res.rects.length, 9);
    }

    function test_signature() {
        const a = [{id: "a", x: 0, y: 0, w: 100, h: 100}];
        const same = [{id: "a", x: 0.2, y: 0, w: 100, h: 100.3}];
        const moved = [{id: "a", x: 5, y: 0, w: 100, h: 100}];
        compare(Layout.signature(a, area), Layout.signature(same, area));
        verify(Layout.signature(a, area) !== Layout.signature(moved, area));
        verify(Layout.signature(a, area) !== Layout.signature(a, {x: 0, y: 100, w: 1900, h: 900}));
    }

    // ---- reserved areas (menu bar, Dock) ----

    readonly property var reserve: ({menubar: 32, barBottom: 116, margin: 32, label: 34, dock: 0})

    function test_freeAreaWithoutDock() {
        const a = Layout.freeArea({w: 1920, h: 1080}, reserve);
        compare(a.x, 32);
        compare(a.y, 148);
        compare(a.w, 1856);
        compare(a.h, 1080 - 32 - 116 - 64 - 34);
    }

    function test_freeAreaReservesTheDockAtTheBottom() {
        const free = Layout.freeArea({w: 1920, h: 1080}, reserve);
        const withDock = Layout.freeArea({w: 1920, h: 1080}, Object.assign({}, reserve, {dock: 76}));
        compare(withDock.h, free.h - 76);
        compare(withDock.y, free.y);
        compare(withDock.x, free.x);
        compare(withDock.w, free.w);
        verify(withDock.y + withDock.h + 34 + 76 <= 1080 - 32);
    }

    function test_freeAreaReservesTheDockOnASideEdge() {
        const free = Layout.freeArea({w: 1920, h: 1080}, reserve);
        const left = Layout.freeArea({w: 1920, h: 1080}, Object.assign({}, reserve, {dockLeft: 82}));
        compare(left.x, free.x + 82);
        compare(left.w, free.w - 82);
        compare(left.h, free.h);
        compare(left.y, free.y);
        const right = Layout.freeArea({w: 1920, h: 1080}, Object.assign({}, reserve, {dockRight: 82}));
        compare(right.x, free.x);
        compare(right.w, free.w - 82);
        compare(right.h, free.h);
    }

    function test_layoutInsideTheDockReservedAreaKeepsWindowsAboveTheDock() {
        const a = Layout.freeArea({w: 1920, h: 1080}, Object.assign({}, reserve, {dock: 76}));
        const input = grid(9, 700, 500, false);
        const res = Layout.layout(input, a, {maxScale: 0.8, gap: 24});
        for (const r of res.rects)
            verify(r.y + r.h <= a.y + a.h + 1e-6);
    }

    // ---- window labels ----

    function overlapsAny(box, rects, skip) {
        for (let i = 0; i < rects.length; i++) {
            if (i !== skip && box.x < rects[i].x + rects[i].w && rects[i].x < box.x + box.w && box.y < rects[i].y + rects[i].h && rects[i].y < box.y + box.h)
                return true;
        }
        return false;
    }

    function test_labelAwareGapLeavesRoomForTheLabel() {
        compare(Layout.labelAwareGap(24, 34, 8), 50);
        compare(Layout.labelAwareGap(80, 34, 8), 80);
    }

    function test_labelUnderTheWindowWhenFree() {
        const rects = [{id: "a", x: 100, y: 100, w: 400, h: 300}, {id: "b", x: 100, y: 500, w: 400, h: 300}];
        const box = Layout.labelRect(rects, 0, 200, 34, 8, {w: 1920, h: 1000});
        compare(box.y, 408);
        compare(box.x, 200);
        verify(!overlapsAny(box, rects, 0));
    }

    function test_labelNeverCoversAnotherWindow() {
        const rects = [{id: "a", x: 100, y: 100, w: 400, h: 300}, {id: "b", x: 100, y: 420, w: 400, h: 300}];
        const box = Layout.labelRect(rects, 0, 200, 34, 8, {w: 1920, h: 1000});
        verify(!overlapsAny(box, rects, 0), JSON.stringify(box));
        const side = [{id: "a", x: 100, y: 100, w: 100, h: 100}, {id: "b", x: 220, y: 100, w: 300, h: 400}];
        const box2 = Layout.labelRect(side, 0, 200, 34, 8, {w: 1920, h: 1000});
        verify(!overlapsAny(box2, side, 0), JSON.stringify(box2));
    }

    function test_labelStaysInsideTheSurface() {
        const rects = [{id: "a", x: 0, y: 900, w: 100, h: 80}];
        const box = Layout.labelRect(rects, 0, 200, 34, 8, {w: 1920, h: 1000});
        verify(box.x >= 8 && box.y + box.h <= 1000 - 8);
    }
}
