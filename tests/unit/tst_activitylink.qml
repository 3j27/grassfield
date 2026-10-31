import QtQuick
import QtTest
import "../../shell/services/ActivityLinkLogic.js" as Logic

// Activity Monitor's links with the shell (ADR-0038 f, AD29; spec AM60, AM61): the runtime folder of a display, the
// projection's body (pids and app ids, never a title; at most 256 windows; the marked pids once each) and `activity quit`'s
// answer and the windows it closes.
TestCase {
    name: "ActivityLink"

    function test_runtimeFolderPerDisplay() {
        compare(Logic.runtimeDir("/run/user/1000", "wayland-1"), "/run/user/1000/grassfield/activity-wayland-1");
        compare(Logic.runtimeDir("/run/user/1000/", "/tmp/nested/wayland-9"), "/run/user/1000/grassfield/activity-wayland-9");
        compare(Logic.runtimeDir("/run/user/1000", "wl:0 x"), "/run/user/1000/grassfield/activity-wl_0_x");
        compare(Logic.runtimeDir("", "wayland-1"), "");
        compare(Logic.runtimeDir("relative", "wayland-1"), "");
        compare(Logic.runtimeDir("/run/user/1000", ""), "");
        compare(Logic.runtimeDir("/run/user/1000", "/tmp/"), "");
    }

    function test_projectionHoldsNoTitle() {
        const body = JSON.parse(Logic.projection([
            {pid: 4242, cls: "foot", title: "secret.txt — vim", idleInhibit: false},
            {pid: 0, cls: "chromium", title: "not read yet"},
            {pid: 1, cls: "init", title: ""},
            {pid: 5000, cls: "mpv", title: "film", idleInhibit: true}
        ], [{standin: 77, pid: 4242, cls: "foot", title: "x"}, {standin: 78, pid: 4242, cls: "foot", title: "y"}, {standin: 79, pid: 1}]));
        compare(JSON.stringify(body.windows), JSON.stringify([{pid: 4242, app: "foot", idleInhibit: false}, {pid: 5000, app: "mpv", idleInhibit: true}]));
        compare(JSON.stringify(body.notResponding), "[4242]");
        verify(JSON.stringify(body).indexOf("secret") < 0 && JSON.stringify(body).indexOf("film") < 0, "no title");
        verify(body.v === undefined && body.writer === undefined, "the script adds them");
    }

    function test_projectionBound() {
        const many = [];
        for (let i = 0; i < 300; i++)
            many.push({pid: 100 + i, cls: "app"});
        compare(JSON.parse(Logic.projection(many, [])).windows.length, Logic.MAX_WINDOWS);
        compare(Logic.projection(null, null), "{\"windows\":[],\"notResponding\":[]}");
    }

    function test_quitPlan() {
        const pids = [300, 0, 301, 300];
        compare(Logic.quitPlan(300, pids).answer, "ok");
        compare(Logic.quitPlan(300, pids).indexes.join(","), "0,3");
        compare(Logic.quitPlan(302, pids).answer, "no-windows");
        for (const bad of [0, 1, -5, 2.5, NaN])
            compare(Logic.quitPlan(bad, [bad]).answer, "refused", "pid " + bad);
    }
}
