import QtQuick
import QtTest
import "../../apps/settings/qml/Keyboard.js" as Keyboard

// Settings > Keyboard (ADR-0031 amendment): the Grassfield-owned keyboard.lua (only the keys chosen, the rules of
// config/hypr/grassfield/input.lua), the session's layout from /etc/vconsole.conf, xkb's base.lst, the repeat stops; then the page
// writing the file and the Input Sources sheet adding, removing and moving layouts.
TestCase {
    id: testCase
    name: "SettingsKeyboard"
    width: 700
    height: 900
    visible: true
    when: windowShown

    function test_parseAndSerialize() {
        compare(Keyboard.parse(""), {});
        const text = Keyboard.serialize({rate: 15, delay: 600, sources: [{layout: "us", variant: ""}, {layout: "fr", variant: "bepo"}]});
        verify(text.indexOf("  repeat_rate = 15,\n") >= 0);
        verify(text.indexOf("  kb_layout = \"us,fr\",\n") >= 0);
        verify(text.indexOf("  kb_variant = \",bepo\",\n") >= 0);
        compare(Keyboard.parse(text), {rate: 15, delay: 600, sources: [{layout: "us", variant: ""}, {layout: "fr", variant: "bepo"}]});
        // Only what was chosen: no key, no line (the session's value stays).
        compare(Keyboard.serialize({rate: 0}).match(/=/g).length, 1);
        compare(Keyboard.parse(Keyboard.serialize({})), {});
        // Out of range, mistyped, too many layouts, a bad variant: left out, as input.lua does.
        compare(Keyboard.parse("return {\n  repeat_rate = 101,\n  repeat_delay = 50,\n}\n"), {});
        compare(Keyboard.parse("  repeat_rate = 1.5,\n"), {});
        compare(Keyboard.parse('  kb_layout = "us,fr,de,es,it",\n'), {});
        compare(Keyboard.parse('  kb_layout = "us,FR",\n'), {});
        // Variants that do not fit are dropped and the layouts stay, as input.lua does.
        compare(Keyboard.parse('  kb_layout = "us,fr",\n  kb_variant = "intl;x,bepo",\n').sources, [{layout: "us", variant: ""}, {layout: "fr", variant: ""}]);
        // A variant list of the wrong length: no variants.
        compare(Keyboard.parse('  kb_layout = "us,fr",\n  kb_variant = "intl",\n').sources, [{layout: "us", variant: ""}, {layout: "fr", variant: ""}]);
        // The writer never writes what the reader would refuse.
        compare(Keyboard.serialize({rate: 500, delay: 7, sources: [{layout: "US", variant: ""}]}).indexOf("="), -1);
    }

    function test_sessionAndStops() {
        compare(Keyboard.sessionSources("KEYMAP=fr\nXKBLAYOUT=fr\nXKBVARIANT=bepo\n"), [{layout: "fr", variant: "bepo"}]);
        compare(Keyboard.sessionSources('XKBLAYOUT="us,de"\nXKBVARIANT=",nodeadkeys"\n'), [{layout: "us", variant: ""}, {layout: "de", variant: "nodeadkeys"}]);
        compare(Keyboard.sessionSources(""), [{layout: "us", variant: ""}]);
        // Omarchy's 40 and 250 are stops: the session's values sit on a stop.
        compare(Keyboard.RATES[Keyboard.nearestIndex(Keyboard.RATES, Keyboard.SESSION_RATE)], 40);
        compare(Keyboard.DELAYS[Keyboard.nearestIndex(Keyboard.DELAYS, Keyboard.SESSION_DELAY)], 250);
        compare(Keyboard.RATES.length, 8);
        compare(Keyboard.DELAYS.length, 6);
        compare(Keyboard.RATES[0], 0);
    }

    function test_layouts() {
        const l = Keyboard.parseLayouts("! model\n  pc105 Generic 105-key PC\n! layout\n  us              English (US)\n  fr              French\n"
            + "! variant\n  intl            us: English (US, intl., with dead keys)\n  bepo            fr: French (BEPO)\n! option\n  grp:ctrl_space_toggle Ctrl+Space\n");
        // Sorted in the user's collation, as the UI lists them (macOS does): the order of "English (US)" and
        // "English (US, intl., ...)" depends on the locale (")" before "," in C, after it in en_US), so the test checks
        // what holds in every locale: the same entries, each one not after the next under that collation, the language
        // groups apart and a name before the names it prefixes.
        const names = l.all.map(x => x.name);
        compare(names.slice().sort(), ["English (US)", "English (US, intl., with dead keys)", "French", "French (BEPO)"].sort());
        for (let i = 1; i < names.length; ++i)
            verify(names[i - 1].localeCompare(names[i]) <= 0, names[i - 1] + " sorts after " + names[i]);
        compare(names.slice(2), ["French", "French (BEPO)"]);
        verify(names.slice(0, 2).every(n => n.startsWith("English (US")));
        compare(Keyboard.sourceName({layout: "fr", variant: "bepo"}, l.names), "French (BEPO)");
        compare(Keyboard.sourceName({layout: "xx", variant: ""}, l.names), "xx");
    }

    Component {
        id: fakeBackend
        QtObject {
            property string configFile: "/home/u/.config/grassfield/grassfield.json"
            property string bindingsFile: "/nowhere/bindings.lua"
            property var files: ({})
            property var writes: []
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function writeText(path: string, text: string): string {
                writes.push({path: path, text: text});
                files[path] = text;
                return "";
            }
        }
    }

    Component {
        id: fakeStore
        QtObject {
            function value(key: string): var {
                return "automatic";
            }
            function set(key: string, value: var): void {
            }
        }
    }

    function test_pageWritesOnlyWhatIsChosen() {
        const backend = createTemporaryObject(fakeBackend, testCase);
        backend.files = {"/etc/vconsole.conf": "XKBLAYOUT=fr\n"};
        const store = createTemporaryObject(fakeStore, testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/KeyboardPage.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {backend: backend, store: store, width: 700, height: 900});
        // Nothing chosen: the session's values and layout.
        compare(page.rateIndex, 6);
        compare(page.delayIndex, 5);
        compare(page.sources, [{layout: "fr", variant: ""}]);
        page.change("rate", 15);
        compare(backend.writes.length, 1);
        compare(backend.writes[0].path, "/home/u/.config/grassfield/keyboard.lua");
        compare(Keyboard.parse(backend.writes[0].text), {rate: 15});
        page.setSources([{layout: "fr", variant: ""}, {layout: "us", variant: "intl"}]);
        compare(Keyboard.parse(backend.writes[1].text), {rate: 15, sources: [{layout: "fr", variant: ""}, {layout: "us", variant: "intl"}]});
        compare(page.sources.length, 2);
    }

    SignalSpy {
        id: changedSpy
        signalName: "changed"
    }

    function test_inputSourcesSheet() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/InputSourcesSheet.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const sheet = createTemporaryObject(comp, testCase, {width: 700, height: 900});
        changedSpy.target = sheet;
        changedSpy.clear();
        sheet.openWith([{layout: "us", variant: ""}], {names: {}, all: []});
        sheet.add({layout: "fr", variant: "bepo"});
        compare(sheet.sources, [{layout: "us", variant: ""}, {layout: "fr", variant: "bepo"}]);
        compare(sheet.selected, 1);
        // A source already there is not added twice.
        sheet.add({layout: "us", variant: ""});
        compare(sheet.sources.length, 2);
        sheet.move(-1);
        compare(sheet.sources[0], {layout: "fr", variant: "bepo"});
        compare(sheet.selected, 0);
        sheet.add({layout: "de", variant: ""});
        sheet.add({layout: "es", variant: ""});
        sheet.add({layout: "it", variant: ""});
        compare(sheet.sources.length, Keyboard.MAX_LAYOUTS);
        // The fifth layout was not added: four changes (two adds, a move, two more adds less the refused one).
        compare(changedSpy.count, 4);
        compare(changedSpy.signalArguments[3][0].length, 4);
    }

    // A Latin layout always leads (Omarchy's list, the rule of input.lua's latin_first): the bindings resolve against the first
    // layout and a Latin password has to be typeable at the lock screen.
    function test_latinFirst() {
        verify(Keyboard.latin("us"));
        verify(Keyboard.latin("fr"));
        verify(!Keyboard.latin("ru"));
        verify(!Keyboard.latin("ara"));
        compare(Keyboard.NON_LATIN.length, 29);
        compare(Keyboard.latinFirst([{layout: "ru", variant: ""}]), [{layout: "us", variant: ""}, {layout: "ru", variant: ""}]);
        compare(Keyboard.latinFirst([{layout: "ru", variant: "phonetic"}, {layout: "ua", variant: ""}, {layout: "fr", variant: "bepo"}]),
            [{layout: "fr", variant: "bepo"}, {layout: "ru", variant: "phonetic"}, {layout: "ua", variant: ""}]);
        const kept = [{layout: "de", variant: ""}, {layout: "ru", variant: ""}];
        compare(Keyboard.latinFirst(kept), kept);
        const four = Keyboard.latinFirst(["ru", "ua", "by", "gr"].map(l => ({layout: l, variant: ""})));
        compare(four.map(s => s.layout), ["us", "ru", "ua", "by"]);
        compare(Keyboard.latinFirst([]), [{layout: "us", variant: ""}]);
    }

    function test_inputSourcesSheetKeepsLatinFirst() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/InputSourcesSheet.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const sheet = createTemporaryObject(comp, testCase, {width: 700, height: 900});
        changedSpy.target = sheet;
        changedSpy.clear();
        // A single non-Latin layout (/etc/vconsole.conf): shown as the session applies it, U.S. first; nothing is written.
        sheet.openWith([{layout: "ru", variant: ""}], {names: {}, all: []});
        compare(sheet.sources, [{layout: "us", variant: ""}, {layout: "ru", variant: ""}]);
        compare(changedSpy.count, 0);
        // The last Latin source cannot be removed; another one can.
        sheet.selected = 0;
        verify(!sheet.canRemove);
        sheet.remove();
        compare(sheet.sources.length, 2);
        sheet.selected = 1;
        verify(sheet.canRemove);
        // A non-Latin layout never moves first, by key or by drag.
        sheet.move(-1);
        compare(sheet.sources[0].layout, "us");
        compare(changedSpy.count, 0);
        sheet.add({layout: "fr", variant: "bepo"});
        compare(changedSpy.count, 1);
        sheet.moveTo(0);
        compare(sheet.sources.map(s => s.layout), ["fr", "us", "ru"]);
        // Removing the first Latin source brings the next Latin one first.
        sheet.selected = 0;
        sheet.moveTo(2);
        compare(sheet.sources.map(s => s.layout), ["us", "ru", "fr"]);
        sheet.selected = 0;
        verify(sheet.canRemove);
        sheet.remove();
        compare(sheet.sources, [{layout: "fr", variant: "bepo"}, {layout: "ru", variant: ""}]);
        compare(changedSpy.signalArguments[changedSpy.count - 1][0], sheet.sources);
    }

    function test_inputSourcesDrag() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/InputSourcesSheet.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const sheet = createTemporaryObject(comp, testCase, {width: 700, height: 900});
        changedSpy.target = sheet;
        changedSpy.clear();
        sheet.openWith([{layout: "us", variant: ""}, {layout: "ru", variant: ""}, {layout: "fr", variant: ""}], {names: {}, all: []});
        const list = findChild(sheet, "inputSourceList");
        verify(list);
        const row = list.height / sheet.sources.length;
        waitForRendering(sheet);
        // A press selects; a drag moves the pressed source row by row (here the third to the first).
        mousePress(list, list.width / 2, row * 2.5);
        compare(sheet.selected, 2);
        mouseMove(list, list.width / 2, row * 1.5);
        mouseMove(list, list.width / 2, row * 0.5);
        mouseRelease(list, list.width / 2, row * 0.5);
        compare(sheet.sources.map(s => s.layout), ["fr", "us", "ru"]);
        compare(sheet.selected, 0);
        // Dragging the non-Latin source to the top is refused.
        mousePress(list, list.width / 2, row * 2.5);
        mouseMove(list, list.width / 2, row * 1.5);
        mouseMove(list, list.width / 2, row * 0.5);
        mouseRelease(list, list.width / 2, row * 0.5);
        compare(sheet.sources.map(s => s.layout), ["fr", "ru", "us"]);
        // A plain click selects and moves nothing.
        const before = changedSpy.count;
        mouseClick(list, list.width / 2, row * 0.5);
        compare(sheet.selected, 0);
        compare(changedSpy.count, before);
    }
}
