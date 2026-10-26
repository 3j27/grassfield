import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Privacy.js" as Privacy
import "../../apps/settings/qml" as SettingsQml

// Settings > Privacy & Security (ADR-0030, the portal permission store): the state as Privacy.js checks it, the actions it
// builds, the hub's counts, a category's switches, the saved selections forgotten one action each, and the dev guard. The
// backend is a fake: nothing reaches a bus.
TestCase {
    id: testCase
    name: "SettingsPrivacy"
    width: 700
    height: 900
    visible: true
    when: windowShown

    readonly property string tokenA: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
    readonly property string tokenB: "1a2b3c4d-5e6f-4a1b-9c2d-3e4f5a6b7c8d"
    readonly property var stateJson: ({
            location: [{app: "org.example.Maps", allowed: true}, {app: "org.example.Weather", allowed: false}],
            background: [],
            camera: [{app: "org.example.Meet", allowed: true}, {app: "org.example.Booth", allowed: false}],
            remoteDesktop: [],
            screencast: [{app: "org.example.Meet", token: testCase.tokenA}, {app: "org.example.Meet", token: testCase.tokenB},
                {app: "org.example.Studio", token: testCase.tokenA}]
        })

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property var busQueries: []
            property var busActions: []
            readonly property var applicationDirs: ["/apps"]
            // Booth has a desktop entry; the others are shown by their id.
            property var files: ({"/apps/org.example.Booth.desktop": "[Desktop Entry]\nType=Application\nName=Photo Booth\nIcon=booth\n"})
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function busAct(what: string, op: var, tag: string): bool {
                busActions.push({what: what, op: op, tag: tag});
                return true;
            }
        }
    }

    Component {
        id: serviceComp
        SettingsQml.SystemService {}
    }

    Component {
        id: hubComp
        SettingsQml.PrivacyPage {
            anchors.fill: parent
        }
    }

    Component {
        id: categoryComp
        SettingsQml.PrivacyCategoryPage {
            anchors.fill: parent
        }
    }

    function make(comp, props, dev) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev === true});
        const system = createTemporaryObject(serviceComp, testCase, {backend: backend});
        const page = createTemporaryObject(comp, testCase, Object.assign({backend: backend, system: system}, props || {}));
        verify(page);
        return {backend: backend, system: system, page: page};
    }

    function answer(t, json) {
        compare(t.backend.busQueries[t.backend.busQueries.length - 1], {what: "privacy.state", tag: "privacy.state"});
        t.backend.finished("privacy.state", true, JSON.stringify(json === undefined ? testCase.stateJson : json));
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function row(page, text) {
        return find(page, i => i.text === text && i.subtitle !== undefined);
    }

    function test_parse() {
        const s = Privacy.parse(JSON.stringify({
            location: [{app: "org.example.Maps", allowed: true}, {app: "../x", allowed: true}, {app: "org.example.A", allowed: "yes"}, null],
            camera: "nope",
            screencast: [{app: "org.example.Meet", token: testCase.tokenA}, {app: "org.example.Meet", token: testCase.tokenB},
                {app: "org.example.Meet", token: testCase.tokenA}, {app: "org.example.Bad", token: "a b"}]
        }));
        compare(s.location, [{app: "org.example.Maps", allowed: true}], "a path, a value that is not a boolean and null are dropped");
        compare(s.camera, []);
        compare(s.background, []);
        compare(s.remoteDesktop, [], "every key is there");
        compare(s.screencast, [{app: "org.example.Meet", tokens: [testCase.tokenA, testCase.tokenB]}], "one entry per app, a token once");
        compare(Privacy.parse("not json").location, []);
        compare(Privacy.parse("null").screencast, []);
    }

    function test_count() {
        const s = Privacy.parse(JSON.stringify(testCase.stateJson));
        compare(Privacy.count(s, "location"), 1, "those allowed");
        compare(Privacy.count(s, "camera"), 1);
        compare(Privacy.count(s, "screencast"), 2, "the apps with a saved selection");
        compare(Privacy.count(s, "remoteDesktop"), 0);
        compare(Privacy.count(null, "camera"), 0);
    }

    function test_actions() {
        compare(Privacy.allow("camera", "org.example.Meet", false), {op: "privacy.allow", category: "camera", app: "org.example.Meet", on: false});
        compare(Privacy.allow("location", "org.example.Maps", true).category, "location");
        compare(Privacy.allow("microphone", "org.example.Meet", true), null, "a category the store does not keep here");
        compare(Privacy.allow("camera", "../etc", true), null);
        compare(Privacy.allow("camera", "org.example.Meet", "yes"), null);
        compare(Privacy.allow("screencast", "org.example.Meet", true), null, "a saved selection has no switch");
        compare(Privacy.forget("screencast", testCase.tokenA), {op: "privacy.forget", kind: "screencast", token: testCase.tokenA});
        compare(Privacy.forget("remoteDesktop", "abc").kind, "remoteDesktop");
        compare(Privacy.forget("camera", "abc"), null);
        compare(Privacy.forget("screencast", "a b"), null);
        compare(Privacy.forget("screencast", ""), null);
        compare(Privacy.entryFile("org.example.Meet"), "org.example.Meet.desktop");
        compare(Privacy.entryFile("../../x"), "");
    }

    // The hub asks the store once, then counts: Location's value, each category's "None", "1 app", "2 apps".
    function test_hubCounts() {
        const t = make(hubComp);
        compare(t.backend.busQueries.length, 1);
        const location = find(t.page, i => i.text === "Location Services" && i.value !== undefined);
        compare(location.value, "", "nothing until the store answers");
        answer(t);
        compare(location.value, "1");
        compare(row(t.page, "Background Apps").subtitle, "None");
        compare(row(t.page, "Camera").subtitle, "1 app");
        compare(row(t.page, "Remote Desktop").subtitle, "None");
        compare(row(t.page, "Screen Sharing").subtitle, "2 apps");
        let opened = "";
        t.page.open.connect(id => opened = id);
        row(t.page, "Screen Sharing").clicked();
        compare(opened, "privacy-screen-sharing");
        location.clicked();
        compare(opened, "privacy-location");
    }

    // The store cannot be read: the reason under the categories, no counts.
    function test_hubStoreMissing() {
        const t = make(hubComp);
        t.backend.failed("privacy.state", "the service is not running");
        t.backend.finished("privacy.state", false, "");
        compare(row(t.page, "Camera").subtitle, "");
        verify(find(t.page, i => i.footnote !== undefined && i.footnote.indexOf("the service is not running") >= 0));
    }

    // A switch sends the store's action, waits for it, then reads the store again; the app's name is its desktop entry's.
    function test_cameraSwitch() {
        const t = make(categoryComp, {key: "camera"});
        answer(t);
        const booth = find(t.page, i => i.title === "Photo Booth" && i.checked !== undefined);
        verify(booth, "the name from org.example.Booth.desktop");
        compare(booth.subtitle, "org.example.Booth");
        compare(booth.checked, false);
        const meet = find(t.page, i => i.title === "org.example.Meet" && i.checked !== undefined);
        verify(meet, "no desktop entry: its id");
        compare(meet.subtitle, "", "the id is not repeated");
        booth.toggled(true);
        compare(t.backend.busActions.length, 1);
        compare(t.backend.busActions[0].op, {op: "privacy.allow", category: "camera", app: "org.example.Booth", on: true});
        compare(t.backend.busActions[0].tag, "privacy.act");
        verify(!booth.toggleEnabled, "busy until the store answers");
        meet.toggled(false);
        compare(t.backend.busActions.length, 1, "one change at a time");
        const queries = t.backend.busQueries.length;
        t.backend.finished("privacy.act", true, "");
        compare(t.backend.busQueries.length, queries + 1, "read again");
        verify(booth.toggleEnabled);
    }

    // Remove forgets every saved selection of the selected app, one action after the other, then reads the store again.
    function test_forgetSavedSelections() {
        const t = make(categoryComp, {key: "screencast"});
        answer(t);
        const meet = find(t.page, i => i.title === "org.example.Meet" && i.showToggle !== undefined);
        compare(meet.subtitle, "2 saved choices");
        verify(!meet.showToggle);
        const remove = find(t.page, i => i.accessibleName === "Remove the selected app");
        verify(!remove.enabled, "nothing selected");
        meet.clicked();
        verify(remove.enabled);
        remove.clicked();
        compare(t.backend.busActions.map(a => a.op), [{op: "privacy.forget", kind: "screencast", token: testCase.tokenA}]);
        t.backend.finished("privacy.act", true, "");
        compare(t.backend.busActions.map(a => a.op.token), [testCase.tokenA, testCase.tokenB]);
        const queries = t.backend.busQueries.length;
        t.backend.finished("privacy.act", true, "");
        compare(t.backend.busActions.length, 2);
        compare(t.backend.busQueries.length, queries + 1);
    }

    // A failed action stops the queue and shows the store's reason.
    function test_forgetFailure() {
        const t = make(categoryComp, {key: "screencast"});
        answer(t);
        find(t.page, i => i.title === "org.example.Meet" && i.showToggle !== undefined).clicked();
        t.page.forgetSelected();
        t.backend.failed("privacy.act", "Unable to write the permission database");
        t.backend.finished("privacy.act", false, "");
        compare(t.backend.busActions.length, 1, "the second token is not tried");
        verify(find(t.page, i => i.footnote !== undefined && i.visible && i.footnote.indexOf("Unable to write the permission database") >= 0));
    }

    // In a dev session the state is read and nothing is sent.
    function test_devGuard() {
        const t = make(categoryComp, {key: "location"}, true);
        answer(t);
        const maps = find(t.page, i => i.title === "org.example.Maps" && i.checked !== undefined);
        maps.toggled(false);
        compare(t.backend.busActions.length, 0);
        verify(t.system.suppressedNote);
        verify(maps.toggleEnabled, "not left busy");
    }

    function test_emptyCategory() {
        const t = make(categoryComp, {key: "remoteDesktop"});
        answer(t);
        verify(find(t.page, i => i.title === "No saved choices" && i.visible));
    }
}
