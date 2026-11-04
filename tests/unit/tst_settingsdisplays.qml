import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Displays.js" as Displays
import "../../apps/settings/qml/System.js" as System
import "../../apps/settings/qml" as SettingsQml

// Settings > Displays (ADR-0031): the state the shell publishes, the resolution choices (Larger Text … More Space) and refresh
// rates of a monitor, the lines of displays.conf and of a trial (the same rule as config/hypr/grassfield/displays.lua), the
// merge of a change into the kept lines, and the arrangement's snap. Then the page on a fake backend: a choice writes a trial
// with the kept lines of the other displays and asks for the keep sheet; Keep is taken only while the shell says the trial is
// applied (an earlier Keep is refused, not held; the sheet stays open), and displays.conf is written only once the shell kept
// it (a Keep after the shell's deadline writes nothing); Revert marks it; the shell taking it back, or not answering, ends it; Arrange tries the moved displays; a display
// without a usable name is never written; brightness is the shell's command and nothing in a dev session.
TestCase {
    id: testCase
    name: "SettingsDisplays"
    width: 700
    height: 900
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property string displaysStateFile: "/run/user/1000/grassfield-displays.json"
            property string stateText: ""
            property var conf: []
            property var calls: []
            property var actions: []
            property string trialError: ""
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal fileChanged(string path)
            function readText(path: string): var {
                return {exists: stateText !== "", ok: path === displaysStateFile && stateText !== "", text: stateText};
            }
            function watch(path: string): bool {
                return true;
            }
            function displaysConf(): var {
                return conf;
            }
            function writeDisplaysConf(lines: var): string {
                calls.push({call: "conf", lines: lines});
                return "";
            }
            function writeDisplayTrial(id: string, until: real, lines: var): string {
                calls.push({call: "trial", id: id, until: until, lines: lines});
                return trialError;
            }
            function markDisplayTrial(state: string, id: string): string {
                calls.push({call: "mark", state: state, id: id});
                return "";
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push(argv);
                return true;
            }
            function query(argv: var, tag: string): void {
            }
        }
    }

    // The settings store of the page: `displays.main` as a ConfigStore keeps it, writes recorded.
    Component {
        id: fakeStore
        QtObject {
            property var values: ({})
            property var sets: []
            function value(key: string): var {
                void values;
                return values[key] !== undefined ? values[key] : [];
            }
            function set(key: string, v: var): bool {
                sets.push({key: key, value: v});
                const next = Object.assign({}, values);
                next[key] = v;
                values = next;
                return true;
            }
        }
    }

    function makePage(dev, monitors) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev});
        backend.stateText = JSON.stringify({v: 1, monitors: monitors, backlight: {device: "intel_backlight", level: 0.5}, trial: null});
        const sc = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/SystemService.qml"));
        const service = createTemporaryObject(sc, testCase, {backend: backend});
        const pc = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/DisplaysPage.qml"));
        compare(pc.status, Component.Ready, pc.errorString());
        const store = createTemporaryObject(fakeStore, testCase);
        const page = createTemporaryObject(pc, testCase, {backend: backend, system: service, store: store, width: 700, height: 900});
        verify(page);
        return {backend: backend, page: page, service: service, store: store};
    }

    function publish(t, trial) {
        const j = JSON.parse(t.backend.stateText);
        j.trial = trial;
        t.backend.stateText = JSON.stringify(j);
        t.page.refresh();
    }

    readonly property var panelIpc: ({name: "eDP-1", description: "BOE 0x0BCA", width: 2880, height: 1800, physicalWidth: 300, physicalHeight: 190,
        refreshRate: 120, x: 0, y: 0, scale: 2, transform: 0, availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz"]})
    readonly property var externalIpc: ({name: "DP-1", description: "GF Display 27 0001", model: "Display 27", width: 2560, height: 1440,
        physicalWidth: 597, physicalHeight: 336, refreshRate: 60, x: 1440, y: 0, scale: 1, transform: 0, availableModes: ["2560x1440@60.00Hz"]})

    SignalSpy {
        id: keepSpy
        signalName: "keepRequested"
    }

    SignalSpy {
        id: endSpy
        signalName: "trialEnded"
    }

    function test_page_aChoiceIsATrialThenKept() {
        const t = makePage(false, [panelIpc, externalIpc]);
        keepSpy.target = t.page;
        keepSpy.clear();
        endSpy.target = t.page;
        endSpy.clear();
        // The kept line of the other display stays in the trial.
        const other = "v1\tdesc:GF Display 27 0001\t2560x1440@60.00\t1440x0\t1\t0";
        t.backend.conf = [other];
        compare(t.page.monitors.length, 2);
        compare(t.page.choices.length, 5);
        t.page.tryChange({scale: 2.5});
        const trial = t.backend.calls[0];
        compare(trial.call, "trial");
        verify(/^[a-z0-9]{8}$/.test(trial.id));
        const now = Math.floor(Date.now() / 1000);
        verify(trial.until >= now + 14 && trial.until <= now + 15, String(trial.until));
        compare(trial.lines, [other, "v1\tdesc:BOE 0x0BCA\t2880x1800@120.00\t0x0\t2.5\t0"]);
        compare(keepSpy.count, 1);
        compare(keepSpy.signalArguments[0][0], trial.until);
        // One trial at a time.
        verify(!t.page.settable);
        t.page.tryChange({scale: 1.6});
        compare(t.backend.calls.length, 1);
        // Keep before the shell applied the trial (Return twice) is refused and not held: the applied state that follows sends
        // nothing on its own.
        verify(!t.page.trialApplied);
        verify(!t.page.keep());
        publish(t, {id: trial.id, state: "applied"});
        compare(t.backend.calls.length, 1);
        // The mode is on screen: Keep marks the trial kept, once; displays.conf is not written yet.
        verify(t.page.trialApplied);
        verify(t.page.keep());
        verify(!t.page.keep());
        compare(t.backend.calls.slice(1), [{call: "mark", state: "kept", id: trial.id}]);
        compare(endSpy.count, 0);
        // The shell kept it: now displays.conf, for the next login.
        publish(t, {id: trial.id, state: "kept"});
        compare(t.backend.calls.slice(1), [{call: "mark", state: "kept", id: trial.id}, {call: "conf", lines: trial.lines}]);
        compare(endSpy.count, 1);
        verify(t.page.settable);
    }

    function test_page_aLateKeepWritesNothing() {
        const t = makePage(false, [panelIpc]);
        endSpy.target = t.page;
        endSpy.clear();
        // The shell's deadline came before the Keep reached it: it took the trial back; nothing reaches displays.conf.
        t.page.tryChange({scale: 2.5});
        const id = t.backend.calls[0].id;
        publish(t, {id: id, state: "applied"});
        t.page.keep();
        publish(t, {id: id, state: "reverted"});
        compare(t.backend.calls.filter(c => c.call === "conf"), []);
        compare(endSpy.count, 1);
        verify(t.page.notice.indexOf("taken back") >= 0, t.page.notice);
        // Keep after the shell already took it back: nothing at all.
        t.page.tryChange({scale: 1.6});
        const id2 = t.backend.calls[t.backend.calls.length - 1].id;
        publish(t, {id: id2, state: "applied"});
        publish(t, {id: id2, state: "reverted"});
        const before = t.backend.calls.length;
        t.page.keep();
        compare(t.backend.calls.length, before);
        // A shell that never applies the trial: Keep is never taken (the applied timer takes the trial back).
        t.page.tryChange({scale: 1.6});
        verify(!t.page.keep());
        tryCompare(t.page, "trialId", "", 6000);
        compare(t.backend.calls.filter(c => c.call === "mark" && c.state === "kept").length, 1);
        // A shell that applied the trial but never answers the Keep: nothing written, said so.
        t.page.tryChange({scale: 2.5});
        const id3 = t.backend.calls[t.backend.calls.length - 1].id;
        publish(t, {id: id3, state: "applied"});
        t.page.keep();
        tryCompare(t.page, "trialId", "", 6000);
        compare(t.backend.calls.filter(c => c.call === "conf"), []);
        verify(t.page.notice.indexOf("did not answer") >= 0, t.page.notice);
    }

    function test_page_revertAndTheShellsAnswers() {
        const t = makePage(false, [panelIpc]);
        endSpy.target = t.page;
        endSpy.clear();
        t.page.tryChange({hz: 60});
        const id = t.backend.calls[0].id;
        compare(t.backend.calls[0].lines, ["v1\tdesc:BOE 0x0BCA\t2880x1800@60.00\t0x0\t2\t0"]);
        t.page.revert();
        compare(t.backend.calls[1], {call: "mark", state: "revert", id: id});
        compare(endSpy.count, 1);
        // The shell takes a trial back (its deadline): the sheet goes, nothing is written.
        t.page.tryChange({transform: 1});
        const id2 = t.backend.calls[2].id;
        publish(t, {id: id2, state: "applied"});
        publish(t, {id: id2, state: "reverted"});
        compare(endSpy.count, 2);
        compare(t.backend.calls.length, 3);
        // A trial the shell never answers is taken back and said so.
        t.page.tryChange({scale: 1.6});
        const id3 = t.backend.calls[3].id;
        tryCompare(t.page, "trialId", "", 6000);
        compare(t.backend.calls[4], {call: "mark", state: "revert", id: id3});
        verify(t.page.notice.indexOf("did not answer") >= 0, t.page.notice);
        // A trial the backend refuses: no sheet, the reason shown.
        t.backend.trialError = "no folder for a display trial in this session";
        t.page.tryChange({scale: 1.6});
        compare(t.page.trialId, "");
        verify(t.page.notice.indexOf("no folder") >= 0);
    }

    Component {
        id: keepSheet
        Item {
            width: 700
            height: 600
            property alias sheet: sheet
            property int kept: 0
            SettingsQml.DisplayKeepSheet {
                id: sheet
                onKeep: parent.kept++
            }
        }
    }

    function test_keepSheetWaitsForTheModeOnScreen() {
        const host = createTemporaryObject(keepSheet, testCase);
        host.sheet.openFor(Math.floor(Date.now() / 1000) + 15);
        // Not applied yet: Keep (Return) leaves the sheet open and says why; no keep is sent.
        host.sheet.confirm();
        verify(host.sheet.visible);
        compare(host.kept, 0);
        verify(host.sheet.errorText !== "");
        // Applied: Keep is sent once and the sheet closes.
        host.sheet.canKeep = true;
        host.sheet.confirm();
        verify(!host.sheet.visible);
        compare(host.kept, 1);
    }

    function test_page_arrangeAndUnnamedDisplays() {
        const t = makePage(false, [panelIpc, externalIpc]);
        t.page.arrange([{name: "DP-1", x: -2560, y: 0}]);
        compare(t.backend.calls[0].lines, ["v1\tdesc:GF Display 27 0001\t2560x1440@60.00\t-2560x0\t1\t0"]);
        t.page.revert();
        // A display without a description: shown, never written.
        const u = makePage(false, [Object.assign({}, panelIpc, {description: ""})]);
        verify(!u.page.nameable);
        verify(!u.page.settable);
        u.page.tryChange({scale: 2.5});
        compare(u.backend.calls.length, 0);
    }

    function test_page_brightness() {
        compare(System.setBrightness("intel_backlight", 0.456), ["brightnessctl", "-q", "-d", "intel_backlight", "set", "46%"]);
        compare(System.setBrightness("-d", 0.5), null);
        compare(System.setBrightness("a/b", 0.5), null);
        compare(System.setBrightness("intel_backlight", NaN), null);
        const dev = makePage(true, [panelIpc]);
        verify(dev.service.dev);
        compare(dev.service.act("brightness", System.setBrightness("intel_backlight", 0.3), "display.brightness"), false);
        compare(dev.backend.actions.length, 0);
    }

    // ADR-0044: with two displays the page knows the main one (the built-in panel by default), and making the other main writes
    // displays.main through the store, keyed by identity (make, model and serial from Hyprland's monitors in the state file), never by the connector.
    function test_page_mainDisplay() {
        const monitors = [{name: "eDP-1", make: "LG", model: "LGD", serial: "123", description: "LGD x", width: 1920, height: 1080, refreshRate: 60, x: 0, y: 0, scale: 1, transform: 0, availableModes: []},
                          {name: "DP-2", make: "Dell", model: "DELL", serial: "ABC", description: "DELL x", width: 1920, height: 1080, refreshRate: 60, x: 1920, y: 0, scale: 1, transform: 0, availableModes: []}];
        const u = makePage(false, monitors);
        compare(u.page.mainName, "eDP-1");
        u.page.selected = "DP-2";
        compare(u.page.isMain, false);
        u.page.makeMain("DP-2");
        compare(u.store.sets.length, 1);
        compare(u.store.sets[0].key, "displays.main");
        compare(u.store.sets[0].value, [{set: ["s:Dell|DELL|ABC", "s:LG|LGD|123"], main: "s:Dell|DELL|ABC"}]);
        compare(u.page.mainName, "DP-2");
        compare(u.page.isMain, true);
        // The same panel on another port is still the main display.
        compare(DisplayRole.resolve(u.store.values["displays.main"], [{name: "HDMI-A-1", make: "Dell", model: "DELL", serial: "ABC"}, {name: "eDP-1", make: "LG", model: "LGD", serial: "123"}]).name, "HDMI-A-1");
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

    // A drag keeps its own value (as Sound's volume does): a reading taken meanwhile does not move the knob back; the next does.
    function test_page_brightnessHoldsWhileDragging() {
        const t = makePage(false, [panelIpc]);
        compare(t.page.backlight.level, 0.5);
        const row = find(t.page, i => i.title === "Brightness" && i.busy !== undefined);
        verify(row);
        const slider = find(row, i => i.moved !== undefined && i.local !== undefined);
        verify(slider);
        slider.local = 0.8;
        slider.moved(0.8);
        compare(t.backend.actions, [["brightnessctl", "-q", "-d", "intel_backlight", "set", "80%"]]);
        verify(row.busy);
        // The shell's state still says the old level while the drag goes on.
        const j = JSON.parse(t.backend.stateText);
        j.backlight.level = 0.45;
        t.backend.stateText = JSON.stringify(j);
        t.page.refresh();
        compare(t.page.backlight.level, 0.5, "the drag's reading is kept");
        compare(slider.shown, 0.8, "the knob stays under the pointer");
        // Once the drag is applied, the next reading follows.
        tryVerify(() => !row.busy);
        j.backlight.level = 0.8;
        t.backend.stateText = JSON.stringify(j);
        t.page.refresh();
        compare(t.page.backlight.level, 0.8);
        compare(slider.shown, 0.8);
    }

    // The choice in use keeps its accent ring; the keyboard's focus is a ring of its own outside it.
    function test_resolutionChoiceFocusRing() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/ResolutionChoices.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const choices = createTemporaryObject(comp, testCase, {width: 468, current: 1,
            choices: [{scale: 2.5, width: 1152, height: 720, isDefault: false}, {scale: 2, width: 1440, height: 900, isDefault: true},
                {scale: 1.6, width: 1800, height: 1125, isDefault: false}]});
        const cells = choices.children.filter(c => c.inUse !== undefined);
        compare(cells.length, 3);
        const rings = cell => cell.children.filter(r => r.border !== undefined && r.color.a === 0 && r.border.width > 1);
        const inUse = cells[1];
        compare(rings(inUse).length, 2);
        const focus = rings(inUse).find(r => r.border.width === Tokens.controlFocusOutline);
        const accent = rings(inUse).find(r => r.border.width === Tokens.settingsDisplayChoiceRing);
        verify(focus && accent);
        verify(accent.visible && !focus.visible);
        verify(Qt.colorEqual(accent.border.color, Appearance.colors.accent));
        inUse.forceActiveFocus(Qt.TabFocusReason);
        verify(accent.visible && focus.visible, "both: in use and focused");
        verify(Qt.colorEqual(focus.border.color, Appearance.focusRingColor));
        // Outside the accent ring, set off from it.
        compare(accent.x - focus.x, Tokens.iconModePreviewFocusGap + Tokens.controlFocusOutline);
        compare(focus.width - accent.width, 2 * (Tokens.iconModePreviewFocusGap + Tokens.controlFocusOutline));
        // Another choice with the focus: its focus ring only.
        cells[2].forceActiveFocus(Qt.TabFocusReason);
        verify(!focus.visible && accent.visible);
        const other = rings(cells[2]);
        verify(other.find(r => r.border.width === Tokens.controlFocusOutline).visible);
        verify(!other.find(r => r.border.width === Tokens.settingsDisplayChoiceRing).visible);
    }

    readonly property var panel: ({name: "eDP-1", description: "BOE 0x0BCA", make: "BOE", model: "0x0BCA", width: 2880, height: 1800,
        physicalWidth: 300, physicalHeight: 190, refreshRate: 120, x: 0, y: 0, scale: 2, transform: 0,
        modes: [{w: 2880, h: 1800, hz: 120}, {w: 2880, h: 1800, hz: 60}, {w: 2880, h: 1800, hz: 59.94}, {w: 1920, h: 1200, hz: 60}, {w: 2880, h: 1800, hz: 120.001}]})
    readonly property var monitor24: ({name: "DP-1", description: "Dell Inc. DELL P2419H 4GHXRV2", width: 1920, height: 1080, physicalWidth: 530,
        physicalHeight: 300, refreshRate: 60, x: 1440, y: 0, scale: 1, transform: 0, modes: []})

    function test_parseState() {
        const text = JSON.stringify({v: 1, monitors: [
            {name: "eDP-1", description: "BOE 0x0BCA", width: 2880, height: 1800, physicalWidth: 300, physicalHeight: 190, refreshRate: 120, x: 0, y: 0, scale: 2,
             transform: 0, disabled: false, availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz", "junk"]},
            {name: "HDMI-A-1", disabled: true}, {description: "no name"}],
            backlight: {device: "intel_backlight", level: 0.4}, trial: {id: "a1b2", state: "applied"}});
        const s = Displays.parseState(text);
        compare(s.monitors.length, 1);
        compare(s.monitors[0].modes, [{w: 2880, h: 1800, hz: 120}, {w: 2880, h: 1800, hz: 60}]);
        compare(s.backlight, {device: "intel_backlight", level: 0.4});
        compare(s.trial, {id: "a1b2", state: "applied"});
        compare(Displays.parseState("{}"), null);
        compare(Displays.parseState("not json"), null);
        compare(Displays.parseState('{"v":2,"monitors":[]}'), null);
        compare(Displays.parseState('{"v":1,"monitors":[]}').backlight, null);
    }

    function test_defaultScaleAndChoices() {
        // 14" 2880 x 1800: 243 ppi, Hyprland's default 2; macOS's span: 1152 x 720 … 1800 x 1125.
        compare(Displays.defaultScale(panel), 2);
        const c = Displays.scaleChoices(panel);
        compare(c.map(x => x.width + "x" + x.height), ["1152x720", "1200x750", "1440x900", "1728x1080", "1800x1125"]);
        compare(c.filter(x => x.isDefault).map(x => x.scale), [2]);
        compare(Displays.currentChoice(c, 2), 2);
        // A monitor set elsewhere to a scale outside the span is still shown as it is.
        const odd = Object.assign({}, panel, {scale: 1});
        verify(Displays.scaleChoices(odd).some(x => x.scale === 1));
        verify(Displays.scaleChoices(odd).length <= Displays.MAX_CHOICES);
        // 24" 1080p: about 92 ppi, default 1; the only other choice is Larger Text at 1.25 (1536 x 864).
        compare(Displays.defaultScale(monitor24), 1);
        compare(Displays.scaleChoices(monitor24).map(x => x.scale), [1.25, 1]);
        // Without a physical size: 1.
        compare(Displays.defaultScale(Object.assign({}, panel, {physicalWidth: 0})), 1);
    }

    function test_refreshRates() {
        // The modes of the current resolution only, one per rate to the hundredth (120 and 120.001 are one), highest first.
        compare(Displays.refreshRates(panel), [120, 60, 59.94]);
        // The number in the language's format (the UI's locale by default), in one translatable sentence.
        const en = Qt.locale("en_US");
        compare(Displays.hzLabel(120, en), "120 Hz");
        compare(Displays.hzLabel(59.94, en), "59.94 Hz");
        compare(Displays.hzLabel(60.001, en), "60 Hz");
        compare(Displays.hzLabel(59.94, Qt.locale("fr_FR")), "59,94 Hz");
        compare(Displays.hzLabel(59.94), Displays.hzLabel(59.94, Qt.locale()));
    }

    function test_lines() {
        compare(Displays.lineFor(panel, {}), "v1\tdesc:BOE 0x0BCA\t2880x1800@120.00\t0x0\t2\t0");
        compare(Displays.lineFor(panel, {scale: 1.666667, hz: 60, transform: 1, x: -1440, y: 12.4}), "v1\tdesc:BOE 0x0BCA\t2880x1800@60.00\t-1440x12\t1.666667\t1");
        // A display that cannot be named this way is never written.
        compare(Displays.lineFor(Object.assign({}, panel, {description: ""}), {}), "");
        compare(Displays.lineFor(Object.assign({}, panel, {description: "A\tB"}), {}), "");
        compare(Displays.lineFor(Object.assign({}, panel, {description: "x".repeat(161)}), {}), "");
        compare(Displays.lineFor(Object.assign({}, panel, {description: "é".repeat(81)}), {}), "");
        compare(Displays.descOfLine("v1\tdesc:BOE 0x0BCA\t2880x1800@60.00\t0x0\t2\t0"), "BOE 0x0BCA");
        compare(Displays.descOfLine("garbage"), "");
    }

    function test_mergeLines() {
        const kept = ["v1\tdesc:A\t1920x1080@60.00\t0x0\t1\t0", "v1\tdesc:B\t1920x1080@60.00\t1920x0\t1\t0"];
        const fresh = ["v1\tdesc:B\t1920x1080@60.00\t0x1080\t1\t0", "v1\tdesc:C\t1920x1080@60.00\t-1920x0\t1\t0"];
        compare(Displays.mergeLines(kept, fresh), [kept[0], fresh[0], fresh[1]]);
        compare(Displays.mergeLines([], fresh), fresh);
    }

    function test_trialId() {
        let n = 0;
        const id = Displays.trialId(() => (n++ % 10) / 10);
        verify(/^[a-z0-9]{8}$/.test(id), id);
        verify(/^[a-z0-9]{8}$/.test(Displays.trialId(Math.random)));
    }

    function test_snapBeside() {
        // The panel (1440 x 900 logical) at 0,0; the 24" (1920 x 1080) dropped to its right, a little low: it touches the right edge.
        compare(Displays.snapBeside(monitor24, 1500, 300, panel), {x: 1440, y: 300});
        // Dropped far right and low: still to the right (farther that way than down), as low as the two edges still share a pixel.
        compare(Displays.snapBeside(monitor24, 3000, 1400, panel), {x: 1440, y: 899});
        // Dropped below: under the panel, where it was dropped across.
        compare(Displays.snapBeside(monitor24, 500, 1000, panel), {x: 500, y: 900});
        // Dropped to the left.
        compare(Displays.snapBeside(monitor24, -2500, -50, panel), {x: -1920, y: -50});
        // Dropped above, overlapping: it goes above.
        compare(Displays.snapBeside(monitor24, 100, -900, panel), {x: 100, y: -1080});
        // A rotated monitor is placed by its turned size.
        const turned = Object.assign({}, monitor24, {transform: 1});
        compare(Displays.logicalSize(turned), {w: 1080, h: 1920});
        compare(Displays.snapBeside(turned, -900, 0, panel), {x: -1080, y: 0});
    }
}
