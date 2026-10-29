import QtQuick
import QtTest
import Grassfield.Ui

// About This Computer (apps/settings/qml/AboutWindow.qml, ADR-0040 ID-19): the window maps once hostname1 has answered, or
// after settings.aboutWindowRevealTimeout with what it has (P-2, P-6); computer first (the drawing by chassis, the model
// name), then processor, memory, graphics and the product line, whose mark keeps the brand green whatever the accent; a
// window of fixed size; More Info… opens Settings at General > About once, then brings that window back. The backend is a
// fake in a dev session: nothing reaches a bus, a tool or a file.
TestCase {
    id: testCase
    name: "SettingsAbout"
    width: 400
    height: 400
    visible: true
    when: windowShown

    readonly property string host: JSON.stringify({pretty: "", "static": "box", hostname: "box", chassis: "laptop", vendor: "LENOVO", model: "ThinkPad X1 Carbon Gen 11"})

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: true
            readonly property string configFile: "/home/u/.config/grassfield/grassfield.json"
            readonly property string capabilitiesFile: "/run/user/1000/grassfield/capabilities.json"
            readonly property string bindingsFile: "/home/u/.config/hypr/bindings.lua"
            readonly property string stateDir: "/home/u/.local/state"
            readonly property string homeDir: "/home/u"
            readonly property string softwareUpdateFile: "/home/u/.local/state/grassfield/software-update.json"
            readonly property bool omarchyUpdate: true
            readonly property bool updateRunner: false
            readonly property string softwareUpdateRunFile: "/run/user/1000/grassfield/software-update-run.json"
            readonly property var applicationDirs: ["/home/u/.local/share/applications", "/usr/share/applications"]
            readonly property string appVersion: "1.0.0-rc1"
            readonly property string qtVersion: "6.11.0"
            // grassfield.json's text ("" when there is none).
            property string config: ""
            property var files: ({
                    "/proc/cpuinfo": "processor\t: 0\nmodel name\t: AMD Ryzen 7 7840U\nprocessor\t: 1\nmodel name\t: AMD Ryzen 7 7840U\n",
                    "/proc/meminfo": "MemTotal:       32555000 kB\n"
                })
            property var busQueries: []
            property var runs: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal fileChanged(string path)
            function readText(path: string): var {
                if (path === configFile)
                    return {exists: config !== "", ok: config !== "", text: config};
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function writeText(path: string, text: string): string {
                return "";
            }
            function watch(path: string): void {
            }
            function run(argv: var): string {
                runs.push(argv);
                return argv[0] === "lspci" ? "00:02.0 VGA compatible controller: Intel Corporation Raptor Lake-P [Iris Xe Graphics] (rev 04)\n" : "";
            }
            function query(argv: var, tag: string): void {
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                return true;
            }
            function busAct(what: string, op: var, tag: string): bool {
                return true;
            }
            function screens(): var {
                return [];
            }
            function volumes(): var {
                return [];
            }
            function askShellToCheck(tag: string): void {
            }
            function runUpdateChecker(tag: string): void {
            }
        }
    }

    function make(config) {
        // The backend outlives the window: it goes with the test case.
        const backend = fakeBackend.createObject(testCase, {config: config ?? ""});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/AboutWindow.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, {backend: backend, globalMenu: false});
        verify(win);
        return {backend: backend, win: win};
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
        return null;
    }

    function text(win, value) {
        return find(win.contentItem, i => i.text === value && i.font !== undefined);
    }

    function picture(win) {
        return find(win.contentItem, i => i.kind !== undefined && i.laptop !== undefined);
    }

    function row(win, label) {
        return find(win.contentItem, i => i.label === label && i.value !== undefined);
    }

    function cleanup() {
        // The Settings window of More Info… has no parent: close it with the test.
        for (const w of testCase.settingsWindows)
            w.destroy();
        testCase.settingsWindows = [];
    }

    property var settingsWindows: []

    function test_mapsOnceHostname1Answered() {
        const t = make();
        verify(t.backend.busQueries.some(q => q.what === "host.state" && q.tag === "about.host"));
        verify(!t.win.visible, "nothing shows before hostname1 answers");
        t.backend.finished("about.host", true, testCase.host);
        verify(t.win.visible);
        verify(text(t.win, "LENOVO ThinkPad X1 Carbon Gen 11"));
        compare(picture(t.win).kind, "laptop");
        // A late second answer changes nothing.
        t.backend.finished("about.host", false, "");
        verify(t.win.visible);
    }

    function test_mapsAfterTheBoundWithWhatItHas() {
        const t = make();
        verify(!t.win.visible);
        tryVerify(() => t.win.visible, Tokens.settingsAboutWindowRevealTimeout * 3);
        verify(text(t.win, "Computer"));
        compare(picture(t.win).kind, "desktop");
    }

    function test_facts() {
        const t = make();
        t.backend.finished("about.host", true, testCase.host);
        compare(row(t.win, "Processor").value, "AMD Ryzen 7 7840U (2 threads)");
        compare(row(t.win, "Memory").value, "32 GB");
        compare(row(t.win, "Graphics").value, "Intel Iris Xe Graphics");
        compare(row(t.win, "Software").value, "Grassfield Desktop 1.0.0-rc1");
        verify(row(t.win, "Software").mark);
        verify(text(t.win, "Built for Omarchy · based on Arch Linux"));
        verify(t.backend.runs.some(a => a[0] === "lspci"));
        // A window of fixed size, the titlebar-only style.
        compare(t.win.width, Tokens.settingsAboutWindowWidth);
        compare(t.win.minimumWidth, t.win.maximumWidth);
        compare(t.win.minimumHeight, t.win.maximumHeight);
        compare(t.win.height, t.win.minimumHeight);
        compare(t.win.gfChromeRole, "info");
    }

    function test_markKeepsTheBrandGreen() {
        const t = make('{"version":1,"accent":{"color":"blue"}}');
        t.backend.finished("about.host", true, testCase.host);
        compare(Appearance.accentSetting, "blue");
        const mark = find(t.win.contentItem, i => i.name === "grassfield-logo" && i.visible);
        verify(mark);
        verify(Qt.colorEqual(mark.color, Appearance.dark ? Tokens.colorDark.accent : Tokens.colorLight.accent), String(mark.color));
    }

    function test_moreInfoOpensSettingsOnce() {
        const t = make();
        t.backend.finished("about.host", true, testCase.host);
        const button = find(t.win.contentItem, i => i.text === "More Info…" && i.clicked !== undefined);
        verify(button);
        button.clicked();
        const settings = t.win.settingsWindow;
        verify(settings);
        testCase.settingsWindows.push(settings);
        compare(settings.selectedId, "about");
        settings.select("appearance");
        button.clicked();
        compare(t.win.settingsWindow, settings);
        compare(settings.selectedId, "about");
    }
}
