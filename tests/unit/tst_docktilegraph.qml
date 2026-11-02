import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/dock/TileGraph.js" as TileGraph
import "../../shell/dock"

// A-S7, Activity Monitor's Dock tile graph (ADR-0038 f; spec AM62): the file is drawn only when it is version 1, at most
// 2 KiB, of a known kind, 1 to 32 samples in [0, 1] (a number for CPU usage, a pair for the others), from a writer that
// owns one of the app's windows now; the view draws the kinds.
TestCase {
    id: testCase
    name: "DockTileGraph"
    width: 200
    height: 200
    visible: true
    when: windowShown

    function file(o) {
        return JSON.stringify(Object.assign({v: 1, writer: {pid: 4242, start: 9000}, kind: "network", samples: [[0.5, 0.25], [1, 0]]}, o));
    }

    function test_aGraphFromALiveWriter() {
        const g = TileGraph.parse(file({}), [4242]);
        verify(g);
        compare(g.kind, "network");
        compare(g.samples.length, 2);
        compare(TileGraph.parse(file({kind: "cpu-usage", samples: [0.42]}), [4242]).samples[0], 0.42);
        verify(TileGraph.parse(file({kind: "cpu-history", samples: [[0.1, 0.2]]}), [4242]));
        verify(TileGraph.parse(file({kind: "disk"}), [100, 4242]));
    }

    function test_everythingElseIsRefused() {
        compare(TileGraph.parse(file({}), [4243]), null, "a writer that owns no window of the app (stale)");
        compare(TileGraph.parse(file({}), []), null);
        compare(TileGraph.parse(file({v: 2}), [4242]), null, "another version");
        compare(TileGraph.parse(file({kind: "memory-pressure"}), [4242]), null, "an unknown kind");
        compare(TileGraph.parse(file({samples: []}), [4242]), null, "no sample");
        compare(TileGraph.parse(file({samples: [[1.5, 0]]}), [4242]), null, "out of range");
        compare(TileGraph.parse(file({samples: [[-0.1, 0]]}), [4242]), null);
        compare(TileGraph.parse(file({samples: [0.5]}), [4242]), null, "a number where a pair is due");
        compare(TileGraph.parse(file({kind: "cpu-usage", samples: [[0.5, 0.5]]}), [4242]), null, "a pair where a number is due");
        compare(TileGraph.parse(file({samples: [["0.5", 0]]}), [4242]), null, "a string");
        const many = [];
        for (let i = 0; i < 33; i++)
            many.push([0, 0]);
        compare(TileGraph.parse(file({samples: many}), [4242]), null, "33 samples");
        compare(TileGraph.parse(file({writer: {pid: 1, start: 0}}), [1]), null, "pid 1");
        compare(TileGraph.parse(file({writer: {pid: "4242", start: 0}}), [4242]), null);
        compare(TileGraph.parse(file({}) + " ".repeat(2048), [4242]), null, "over 2 KiB");
        compare(TileGraph.parse("not json", [4242]), null);
        compare(TileGraph.parse("[1]", [4242]), null);
        compare(TileGraph.parse("", [4242]), null);
        compare(TileGraph.parse(null, [4242]), null);
    }

    function test_gaugeSegments() {
        compare(TileGraph.litSegments(0, 10), 0);
        compare(TileGraph.litSegments(0.42, 10), 4);
        compare(TileGraph.litSegments(0.96, 10), 10);
        compare(TileGraph.litSegments(1, 10), 10);
    }

    Component {
        id: view
        TileGraphView {
            width: 64
            height: 64
        }
    }

    function test_theViewDrawsEachKind() {
        const v = createTemporaryObject(view, testCase, {graph: null});
        verify(!v.visible, "no graph: the icon shows");
        v.graph = TileGraph.parse(file({kind: "cpu-usage", samples: [0.42]}), [4242]);
        verify(v.visible);
        compare(v.lit, 4);
        compare(v.Accessible.name, "CPU usage");
        v.graph = TileGraph.parse(file({}), [4242]);
        compare(v.Accessible.name, "Network usage");
        compare(v.lit, 0);
        verify(v.bar >= 1);
        waitForRendering(v);
    }
}
