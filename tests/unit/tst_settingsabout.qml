import QtQuick
import QtTest
import Grassfield.Ui

// About This Computer (apps/settings/qml/AboutWindow.qml, ADR-0040 ID-19): the window maps once hostname1 and lspci (a
// query, off the GUI thread) have answered, or after settings.aboutWindowRevealTimeout with what it has, a late line then
// filling in (P-2, P-6); computer first (the drawing by chassis, the model name), then processor, memory, graphics and the
// product line, whose mark keeps the brand green whatever the accent; a line with nothing to say is not shown; a window of
// fixed size that Esc and Ctrl+W close; More Info… asks the running Settings (src/settingsinstance.h) for General > About.
// The backend and the instance are fakes in a dev session: nothing reaches a bus, a tool or a file.
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
            property var queries: []
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
            function readOnlyQuery(argv: var, tag: string, timeoutMs: int, shared: bool): void {
                queries.push({argv: argv, tag: tag, shared: shared});
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

    Component {
        id: fakeInstance
        QtObject {
            property var asked: []
            function openSettings(section: string): void {
                asked.push(section);
            }
        }
    }

    readonly property string lspci: "00:02.0 VGA compatible controller: Intel Corporation Raptor Lake-P [Iris Xe Graphics] (rev 04)\n"

    // hostname1 and lspci answer.
    function answer(t) {
        t.backend.finished("about.host", true, testCase.host);
        t.backend.finished("facts.lspci", true, testCase.lspci);
    }

    // `files` (optional) replaces the fake's /proc files.
    function make(config, files) {
        // The backend outlives the window: it goes with the test case.
        const backend = fakeBackend.createObject(testCase, files ? {config: config ?? "", files: files} : {config: config ?? ""});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/AboutWindow.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const instance = fakeInstance.createObject(testCase);
        const win = createTemporaryObject(comp, testCase, {backend: backend, instance: instance});
        verify(win);
        return {backend: backend, instance: instance, win: win};
    }

    // The window takes the pointer's hover once active (tst_activitymain's tooltips).
    function activate(t) {
        t.win.requestActivate();
        tryVerify(() => t.win.active, 2000, "the window is active");
        wait(50);
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

    function test_mapsOnceHostname1AndLspciAnswered() {
        const t = make();
        verify(t.backend.busQueries.some(q => q.what === "host.state" && q.tag === "about.host"));
        // lspci is a query (off the GUI thread), shared with General > About in the same process.
        verify(t.backend.queries.some(q => q.argv.length === 1 && q.argv[0] === "lspci" && q.tag === "facts.lspci" && q.shared));
        verify(!t.win.visible, "nothing shows before hostname1 answers");
        t.backend.finished("about.host", true, testCase.host);
        verify(!t.win.visible, "nothing shows before lspci answers");
        t.backend.finished("facts.lspci", true, testCase.lspci);
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
        // Graphics is not known yet: no line for it; lspci's late answer fills it in and the window grows to fit.
        verify(!row(t.win, "Graphics").visible);
        const before = t.win.height;
        t.backend.finished("facts.lspci", true, testCase.lspci);
        verify(row(t.win, "Graphics").visible);
        compare(row(t.win, "Graphics").value, "Intel Iris Xe Graphics");
        // The column lays out at the next polish.
        tryVerify(() => t.win.height > before);
        compare(t.win.height, t.win.maximumHeight);
    }

    function test_emptyLinesAreNotShown() {
        // No /proc/meminfo, and lspci fails.
        const t = make(undefined, {"/proc/cpuinfo": "processor\t: 0\nmodel name\t: AMD Ryzen 7 7840U\n"});
        t.backend.finished("about.host", true, testCase.host);
        t.backend.finished("facts.lspci", false, "");
        verify(t.win.visible);
        verify(row(t.win, "Processor").visible);
        verify(!row(t.win, "Memory").visible);
        verify(!row(t.win, "Graphics").visible);
        verify(row(t.win, "Software").visible);
    }

    function test_escAndCtrlWClose() {
        const t = make();
        testCase.answer(t);
        verify(t.win.visible);
        const shortcut = Array.from(t.win.data).find(o => o.sequences !== undefined);
        verify(shortcut, "the window's Shortcut");
        verify(shortcut.sequences.indexOf("Esc") >= 0 && shortcut.sequences.indexOf("Ctrl+W") >= 0, String(shortcut.sequences));
        shortcut.activated();
        verify(!t.win.visible);
    }

    function test_facts() {
        const t = make();
        testCase.answer(t);
        compare(row(t.win, "Processor").value, "AMD Ryzen 7 7840U", "the processor's name alone (About This Mac names the chip alone)");
        compare(row(t.win, "Memory").value, "32 GB");
        compare(row(t.win, "Graphics").value, "Intel Iris Xe Graphics");
        compare(row(t.win, "Software").value, "Grassfield Desktop 1.0.0-rc1");
        verify(row(t.win, "Software").mark);
        verify(text(t.win, "Built for Omarchy · based on Arch Linux"));
        // A window of fixed size, the titlebar-only style.
        compare(t.win.width, Tokens.settingsAboutWindowWidth);
        compare(t.win.minimumWidth, t.win.maximumWidth);
        compare(t.win.minimumHeight, t.win.maximumHeight);
        compare(t.win.height, t.win.minimumHeight);
        compare(t.win.gfChromeRole, "info");
    }

    // Integrator nested pass of 85c2c10 (MINOR): the processor's name and thread count wrapped to three lines in French. The
    // name alone, shortened (SysInfo.cpuShortName), stays on one line cut in the middle, and its full name shows in a tooltip
    // while the pointer rests on it.
    function test_processorOnOneLineWithItsFullNameInATooltip() {
        const full = "11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz";
        const t = make(undefined, {"/proc/cpuinfo": "processor\t: 0\nmodel name\t: " + full + "\nprocessor\t: 1\nmodel name\t: " + full + "\n"});
        testCase.answer(t);
        testCase.activate(t);
        const processor = row(t.win, "Processor");
        compare(processor.value, "Intel Core i7-1165G7");
        const value = find(processor, i => i.text === processor.value && i.lineCount !== undefined);
        verify(value);
        compare(value.lineCount, 1);
        const tip = find(t.win.contentItem, i => i.objectName === "factTip");
        verify(tip);
        verify(!tip.shown, "no tooltip before the pointer rests on it");
        mouseMove(value, 4, value.height / 2);
        tryVerify(() => tip.shown, 1000, "the tooltip shows on the processor's value");
        compare(tip.text, full);
        verify(tip.x >= 0 && tip.x + tip.width <= t.win.width, "inside the window: " + tip.x + " + " + tip.width);
        verify(tip.y >= processor.mapToItem(t.win.contentItem, 0, processor.height).y, "under the value");
        mouseMove(row(t.win, "Software"), 4, 4);
        tryVerify(() => !tip.shown, 1000);
        // Other rows wrap as before and show no tooltip.
        compare(find(row(t.win, "Graphics"), i => i.text === "Intel Iris Xe Graphics" && i.lineCount !== undefined).wrapMode, Text.Wrap);
    }

    function test_aLongProcessorNameIsCutInTheMiddle() {
        const full = "AMD Ryzen Threadripper PRO 7995WX Engineering Sample Extended Edition 96-Cores Liquid Cooled";
        const t = make(undefined, {"/proc/cpuinfo": "processor\t: 0\nmodel name\t: " + full + "\n"});
        testCase.answer(t);
        testCase.activate(t);
        const processor = row(t.win, "Processor");
        compare(processor.value, full, "nothing to shorten");
        const value = find(processor, i => i.text === processor.value && i.lineCount !== undefined);
        compare(value.lineCount, 1);
        verify(value.truncated, "cut");
        compare(value.elide, Text.ElideMiddle);
        compare(processor.height, row(t.win, "Memory").height, "one line high");
        const tip = find(t.win.contentItem, i => i.objectName === "factTip");
        mouseMove(value, value.width / 2, value.height / 2);
        tryVerify(() => tip.shown, 1000, "cut: the tooltip shows");
        compare(tip.text, full);
    }

    function test_aProcessorNameShownWholeHasNoTooltip() {
        const t = make();
        testCase.answer(t);
        testCase.activate(t);
        const processor = row(t.win, "Processor");
        const value = find(processor, i => i.text === processor.value && i.lineCount !== undefined);
        verify(!value.truncated);
        mouseMove(value, 4, value.height / 2);
        wait(100);
        verify(!find(t.win.contentItem, i => i.objectName === "factTip").shown, "the whole name: nothing more to show");
    }

    function test_markKeepsTheBrandGreen() {
        const t = make('{"version":1,"accent":{"color":"blue"}}');
        testCase.answer(t);
        compare(Appearance.accentSetting, "blue");
        const mark = find(t.win.contentItem, i => i.name === "grassfield-logo" && i.visible);
        verify(mark);
        verify(Qt.colorEqual(mark.color, Appearance.dark ? Tokens.colorDark.accent : Tokens.colorLight.accent), String(mark.color));
    }

    function test_moreInfoAsksForGeneralAbout() {
        const t = make();
        testCase.answer(t);
        const button = find(t.win.contentItem, i => i.text === "More Info…" && i.clicked !== undefined);
        verify(button);
        button.clicked();
        compare(t.instance.asked, ["about"]);
        // Again: the same request (the running Settings brings its one window back, src/main.cpp).
        button.clicked();
        compare(t.instance.asked, ["about", "about"]);
        verify(t.win.visible);
    }
}
