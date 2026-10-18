import QtQuick
import QtTest
import "../../apps/settings/qml/System.js" as System

// Settings system sections (Wi-Fi, Bluetooth, Sound, Displays): parsers of the tools' output, action argument vectors,
// arrangement, and the dev guard of SystemService (an action never reaches the backend with GRASSFIELD_DEV=1).
TestCase {
    id: testCase
    name: "SettingsSystem"
    width: 700
    height: 900
    when: windowShown

    Component {
        id: modelComp
        ListModel {}
    }

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property var queries: []
            property var actions: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            function query(argv: var, tag: string): void {
                queries.push(argv);
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push({what: what, argv: argv});
                return true;
            }
        }
    }

    function makeService(dev) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/SystemService.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const service = createTemporaryObject(comp, testCase, {backend: backend});
        verify(service);
        return {backend: backend, service: service};
    }

    readonly property string uuidA: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

    // ---- guard ----

    function test_devGuardSuppressesEveryAction() {
        const t = makeService(true);
        verify(t.service.dev);
        const actions = [
            ["wifi off", System.wifiRadio(false)],
            ["wifi connect", System.wifiConnectKnown(uuidA)],
            ["wifi connect", System.wifiConnectOpen("Cafe")],
            ["wifi disconnect", System.wifiDisconnect("wlo1")],
            ["bluetooth off", System.btPower(false)],
            ["bluetooth connect", System.btConnect("AA:BB:CC:DD:EE:FF", true)],
            ["output device", System.setDefaultDevice(52)],
            ["volume", System.setVolume(52, 0.5)],
            ["mute", System.setMute(52, true)]
        ];
        for (const a of actions) {
            verify(a[1] !== null, a[0]);
                compare(t.service.act(a[0], a[1], "x"), false, a[0]);
        }
        compare(t.backend.actions.length, 0);
        verify(t.service.suppressedNote);
    }

    function test_realSessionPassesActionsThrough() {
        const t = makeService(false);
        verify(!t.service.dev);
        compare(t.service.act("wifi off", System.wifiRadio(false), "x"), true);
        compare(t.backend.actions.length, 1);
        compare(t.backend.actions[0].argv, ["nmcli", "radio", "wifi", "off"]);
        verify(!t.service.suppressedNote);
    }

    function test_invalidActionNeverRuns() {
        const t = makeService(false);
        compare(t.service.act("x", null, "x"), false);
        compare(t.backend.actions.length, 0);
    }

    function test_queriesPass() {
        const t = makeService(true);
        t.service.query(System.QUERY.wifiList, "wifi.list");
        compare(t.backend.queries.length, 1);
    }

    // ---- argument vectors ----

    function test_argvRejectInvalidValues() {
        compare(System.wifiConnectKnown("-x"), null);
        compare(System.wifiConnectKnown("Home"), null);
        compare(System.wifiProfileSsidQuery("Home; reboot"), null);
        compare(System.wifiConnectOpen(""), null);
        compare(System.wifiConnectOpen("a\nb"), null);
        compare(System.wifiDisconnect("wlo1; reboot"), null);
        compare(System.wifiDisconnect("-h"), null);
        compare(System.btConnect("not-a-mac", true), null);
        compare(System.btConnect("AA:BB:CC:DD:EE:FF; ls", true), null);
        compare(System.setDefaultDevice("52"), null);
        compare(System.setDefaultDevice(-1), null);
        compare(System.setVolume(52, NaN), null);
        compare(System.setMute(1.5, true), null);
    }

    function test_argvShapes() {
        compare(System.wifiConnectKnown(uuidA), ["nmcli", "connection", "up", "uuid", uuidA]);
        compare(System.wifiProfileSsidQuery(uuidA), ["nmcli", "-t", "-f", "802-11-wireless.ssid", "connection", "show", "uuid", uuidA]);
        compare(System.btConnect("aa:bb:cc:dd:ee:ff", false), ["bluetoothctl", "disconnect", "aa:bb:cc:dd:ee:ff"]);
        compare(System.setVolume(52, 1.7), ["wpctl", "set-volume", "52", "1.00"]);
        compare(System.setVolume(52, -1), ["wpctl", "set-volume", "52", "0.00"]);
        compare(System.setMute(52, false), ["wpctl", "set-mute", "52", "0"]);
        compare(System.setDefaultDevice(52), ["wpctl", "set-default", "52"]);
    }

    // ---- Wi-Fi ----

    // Exact `nmcli -t` output in the C locale (LC_ALL=C, which Backend forces): SSID-HEX never needs escaping.
    readonly property string wifiListC: "*:486F6D653A203547:72:WPA2\n" + " :486F6D653A203547:40:WPA2\n" + " :43616665:55:--\n" + " :4F6666696365:90:WPA2 802.1X\n" + " ::30:WPA2\n" + " :5765616B:12:WPA3\n"

    function test_wifiList() {
        const list = System.parseWifiList(wifiListC);
        compare(list.map(n => n.ssid), ["Home: 5G", "Office", "Cafe", "Weak"]);
        compare(list[0].active, true);
        compare(list[0].strength, 72);
        compare(list[0].key, "486F6D653A203547|WPA2");
        compare(list[1].enterprise, true);
        compare(list[2].secured, false);
        compare(list[3].secured, true);
        verify(list[0].valid);
    }

    function test_wifiDuplicateKeepsStrongest() {
        const list = System.parseWifiList(" :4E6574:30:WPA2\n :4E6574:80:WPA2\n");
        compare(list.length, 1);
        compare(list[0].strength, 80);
        // Same name, other security: another row, another stable id.
        compare(System.parseWifiList(" :4E6574:30:WPA2\n :4E6574:80:--\n").length, 2);
    }

    // A network name may hold any byte: newline, colon, backslash. It is only ever read from hex, so it can neither
    // add a row nor shift a field.
    function test_wifiHostileName() {
        // "a\nb:c\\d" then a decoy line that would be a second row if the name were printed raw.
        const hostile = "610A623A635C64";
        const list = System.parseWifiList(" :" + hostile + ":50:WPA2\n" + " :4F6666696365:10:--\n");
        compare(list.length, 2);
        compare(list[0].ssid, "a\nb:c\\d");
        compare(list[0].label, "a�b:c\\d");
        compare(list[0].valid, false);
        compare(list[0].strength, 50);
        compare(list[0].secured, true);
        compare(list[1].ssid, "Office");
        // The old raw line of such a network, as nmcli -t -f SSID would print it, is not accepted as a row either.
        compare(System.parseWifiList("*:a\nb\\:c:50:WPA2\n").length, 0);
        compare(System.parseWifiList(" :ZZ:50:WPA2\n").length, 0);
        compare(System.parseWifiList(" :4:50:WPA2\n").length, 0);
        // Invalid UTF-8 shows as replacement characters and can never be passed on to nmcli.
        const bad = System.parseWifiList(" :FF4142:50:WPA2\n");
        compare(bad[0].ssid, "�AB");
        compare(bad[0].valid, false);
        compare(System.wifiConnectOpen(bad[0].ssid), null);
        compare(System.hexToText("E282AC").text, "€");
        compare(System.hexToText("F09F9882").text, "😂");
        compare(System.hexToText("C0AF").valid, false);
        compare(System.textToHex("a\nb:c\\d€"), "610A623A635C64E282AC");
    }

    function test_wifiRadioProfilesDevices() {
        compare(System.parseWifiRadio("enabled\n"), true);
        compare(System.parseWifiRadio("disabled\n"), false);
        compare(System.parseWifiRadio(""), null);
        // French output (what an unforced locale printed) is not understood: Backend forces the C locale.
        compare(System.parseWifiRadio("activé\n"), null);
        compare(System.parseWifiProfiles(uuidA + ":802-11-wireless\n11111111-2222-3333-4444-555555555555:802-3-ethernet\n66666666-7777-8888-9999-000000000000:loopback\n"), [uuidA]);
        const dev = System.parseWifiDevice("lo:loopback:connected (externally)\nwlo1:wifi:connected\np2p-dev-wlo1:wifi-p2p:disconnected\n");
        compare(dev.name, "wlo1");
        compare(dev.connected, true);
        compare(System.parseWifiDevice("eno2:ethernet:unavailable\n"), null);
        compare(System.parseWifiDevice("wlo1:wifi:connecté\n").connected, false);
    }

    function test_profileSsid() {
        compare(System.parseProfileSsid("802-11-wireless.ssid:Home\n"), "486F6D65");
        // ':' and '\\' are escaped by -t; a single-field query keeps even a newline inside the value.
        compare(System.parseProfileSsid("802-11-wireless.ssid:a\nb\\:c\\\\d\n"), "610A623A635C64");
        compare(System.parseProfileSsid("802-11-wireless.ssid:\n"), "");
        compare(System.parseProfileSsid("Error: nope\n"), "");
        compare(System.parseProfileSsid(""), "");
    }

    function test_wifiClickKind() {
        // The known networks match by the profile's SSID, whatever the profile is called.
        const known = {};
        known[System.textToHex("Home")] = uuidA;
        const home = System.parseWifiList(" :" + System.textToHex("Home") + ":50:WPA2\n")[0];
        compare(System.wifiClickKind(home, known), "known");
        compare(System.wifiClickKind({hex: System.textToHex("Home"), active: true, secured: true}, known), "current");
        compare(System.wifiClickKind({hex: "43616665", active: false, secured: false}, known), "open");
        compare(System.wifiClickKind({hex: "4F74686572", active: false, secured: true}, known), "password");
        compare(System.wifiGlyph(90), "wifi-3");
        compare(System.wifiGlyph(40), "wifi-2");
        compare(System.wifiGlyph(5), "wifi-1");
    }

    // ---- Bluetooth ----

    function test_bluetooth() {
        const show = "Controller AA:BB:CC:DD:EE:FF (public)\n\tName: host\n\tPowered: yes\n\tDiscoverable: no\n";
        compare(System.parseBtShow(show), {present: true, powered: true});
        compare(System.parseBtShow(show.replace("yes", "no")), {present: true, powered: false});
        compare(System.parseBtShow("No default controller available\n"), {present: false, powered: false});
        const paired = System.parseBtDevices("\x1b[0mDevice 11:22:33:44:55:66 Headphones\nDevice 77:88:99:AA:BB:CC Zed\nNoise\n");
        compare(paired.map(d => d.name), ["Headphones", "Zed"]);
        const connected = System.parseBtDevices("Device 77:88:99:AA:BB:CC Zed\n");
        const merged = System.bluetoothDevices(paired, connected);
        compare(merged.map(d => d.name), ["Zed", "Headphones"]);
        compare(merged[0].connected, true);
        compare(merged[1].connected, false);
    }

    // ---- Sound ----

    readonly property string wpctlStatus: "PipeWire 'pipewire-0' [1.2.7, user@host, cpu:0/0]\n" + " └─ Clients:\n" + "        33. WirePlumber                         [1.2.7, user@host, pid:1]\n" + "\n" + "Audio\n" + " ├─ Devices:\n" + " │      47. Built-in Audio                      [alsa]\n" + " │\n" + " ├─ Sinks:\n" + " │  *   52. Built-in Audio Analog Stereo        [vol: 0.40]\n" + " │      55. HDMI [Main]                         [vol: 1.00 MUTED]\n" + " │\n" + " ├─ Sink endpoints:\n" + " │\n" + " ├─ Sources:\n" + " │  *   53. Built-in Audio Analog Stereo        [vol: 1.00]\n" + " │\n" + " └─ Streams:\n" + "        60. Firefox\n" + "             62. output_FL > Built-in:playback_FL   [active]\n" + "\n" + "Video\n" + " ├─ Devices:\n" + " ├─ Sources:\n" + " │      70. Camera                              [v4l2]\n" + "\n" + "Settings\n" + " └─ Default Configured Devices:\n"

    function test_audioStatus() {
        const a = System.parseAudio(wpctlStatus);
        compare(a.sinks.length, 2);
        compare(a.sources.length, 1);
        compare(a.sinks[0], {id: 52, name: "Built-in Audio Analog Stereo", isDefault: true, volume: 0.4, muted: false});
        compare(a.sinks[1].name, "HDMI [Main]");
        compare(a.sinks[1].muted, true);
        compare(a.sinks[1].isDefault, false);
        compare(System.defaultOf(a.sources).id, 53);
        compare(System.defaultOf([]), null);
        compare(System.percent(0.405), 41);
        compare(System.volumeGlyph(0.5, true), "volume-mute");
        compare(System.volumeGlyph(0.5, false), "volume-2");
    }

    function test_audioGarbage() {
        const a = System.parseAudio("Could not connect to PipeWire\n");
        compare(a.sinks.length + a.sources.length, 0);
    }

    // ---- Displays ----

    function test_displays() {
        const screens = [{name: "A", x: 0, y: 0, width: 1920, height: 1080, scale: 1, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 59.94, primary: true}, {name: "B", x: 1920, y: 0, width: 1280, height: 720, scale: 1.5, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 0, primary: false}];
        compare(System.resolutionText(screens[0]), "1920 × 1080");
        compare(System.refreshHz(screens[0]), "59.94");
        compare(System.refreshHz(screens[1]), "");
        compare(System.scalePercent(screens[1]), "150");
        const r = System.arrangement(screens, 400, 150, 10, 20);
        compare(r.length, 2);
        // Same scale for both, side by side, inside the box, centred.
        verify(r[1].x >= r[0].x + r[0].w - 0.001);
        verify(r[0].x >= 10 - 0.001 && r[1].x + r[1].w <= 390 + 0.001);
        verify(r[0].y >= 10 - 0.001 && r[0].y + r[0].h <= 140 + 0.001);
        compare(System.arrangement([], 400, 150, 10, 20), []);
    }

    // ---- Stable-id models: a refresh updates rows in place ----

    function keysOf(model) {
        const out = [];
        for (let i = 0; i < model.count; i++)
            out.push(model.get(i).k);
        return out;
    }

    function test_syncModelDiff() {
        const m = createTemporaryObject(modelComp, testCase);
        const item = (k, v) => ({k: k, v: v});
        let created = 0;
        let removed = 0;
        let moved = 0;
        m.rowsInserted.connect(() => created++);
        m.rowsRemoved.connect(() => removed++);
        m.rowsMoved.connect(() => moved++);
        System.syncModel(m, [item("a", 1), item("b", 2), item("c", 3)], "k");
        compare(keysOf(m), ["a", "b", "c"]);
        compare(created, 3);
        // Same keys, one value changed: nothing inserted, removed or moved, one field updated.
        System.syncModel(m, [item("a", 1), item("b", 20), item("c", 3)], "k");
        compare(created, 3);
        compare(removed, 0);
        compare(moved, 0);
        compare(m.get(1).v, 20);
        // Removal in the middle and an addition at the end.
        System.syncModel(m, [item("a", 1), item("c", 3), item("d", 4)], "k");
        compare(keysOf(m), ["a", "c", "d"]);
        compare(removed, 1);
        compare(created, 4);
        // Reordering moves rows, never recreates them.
        System.syncModel(m, [item("d", 4), item("a", 1), item("c", 3)], "k");
        compare(keysOf(m), ["d", "a", "c"]);
        compare(created, 4);
        compare(removed, 1);
        // Insertion before kept rows.
        System.syncModel(m, [item("z", 0), item("d", 4), item("a", 1), item("c", 3)], "k");
        compare(keysOf(m), ["z", "d", "a", "c"]);
        System.syncModel(m, [], "k");
        compare(m.count, 0);
    }

    function test_syncModelAnyOrderReachesTarget() {
        const m = createTemporaryObject(modelComp, testCase);
        const all = ["a", "b", "c", "d", "e"];
        let seed = 7;
        const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
        for (let round = 0; round < 60; round++) {
            const target = all.filter(() => rnd() < 0.6).sort(() => rnd() - 0.5);
            System.syncModel(m, target.map(k => ({k: k, v: round})), "k");
            compare(keysOf(m), target);
        }
    }

    function rowsOf(item, out) {
        for (const c of item.children) {
            if (c.leading !== undefined && c.activated !== undefined)
                out.push(c);
            rowsOf(c, out);
        }
        return out;
    }

    function rowByTitle(page, title) {
        return rowsOf(page, []).find(r => r.title === title) ?? null;
    }

    function openPage(file, t) {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/" + file));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {backend: t.backend, system: t.service, width: 700, height: 900});
        verify(page);
        return page;
    }

    function test_wifiRefreshKeepsRowsAndFocus() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.radio", true, "enabled\n");
        t.backend.finished("wifi.list", true, " :486F6D65:50:WPA2\n :43616665:60:--\n :4F6666696365:40:WPA2\n");
        const home = rowByTitle(page, "Home");
        const cafe = rowByTitle(page, "Cafe");
        verify(home && cafe && rowByTitle(page, "Office"));
        cafe.forceActiveFocus();
        verify(cafe.activeFocus);
        // The next reading: Cafe is now first and stronger, Office is gone, "Zed" appeared, Home changed.
        t.backend.finished("wifi.list", true, " :43616665:90:--\n :486F6D65:55:WPA2\n :5A6564:30:--\n");
        verify(rowByTitle(page, "Cafe") === cafe, "the focused row was rebuilt");
        verify(rowByTitle(page, "Home") === home, "a kept row was rebuilt");
        verify(cafe.activeFocus, "focus lost on refresh");
        compare(cafe.leading, "wifi-3");
        compare(home.leading, "wifi-2");
        compare(rowByTitle(page, "Office"), null);
        verify(rowByTitle(page, "Zed") !== null);
        // An unchanged reading changes nothing.
        t.backend.finished("wifi.list", true, " :43616665:90:--\n :486F6D65:55:WPA2\n :5A6564:30:--\n");
        verify(cafe.activeFocus);
        compare(rowsOf(page, []).length, 3);
    }

    function test_wifiKnownByProfileSsid() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.radio", true, "enabled\n");
        t.backend.finished("wifi.list", true, " :486F6D65:50:WPA2\n");
        compare(page.subtitleOf(page.networks[0]).length > 0, true);
        // A saved profile named "Maison" whose SSID is Home.
        t.backend.finished("wifi.profiles", true, uuidA + ":802-11-wireless\n");
        verify(t.backend.queries.some(q => q.join(" ").indexOf("802-11-wireless.ssid connection show uuid " + uuidA) >= 0));
        t.backend.finished("wifi.ssid:" + uuidA, true, "802-11-wireless.ssid:Home\n");
        compare(System.wifiClickKind(page.networks[0], page.known), "known");
        compare(page.subtitleOf(page.networks[0]), "Known network");
    }

    function test_actionFailureShowsReason() {
        const t = makeService(false);
        const page = openPage("WifiPage.qml", t);
        t.backend.finished("wifi.radio", true, "enabled\n");
        t.backend.failed("wifi.act", "Error: Connection activation failed: Secrets were required");
        compare(t.service.errors["wifi.act"], "Error: Connection activation failed: Secrets were required");
        // The next action clears it; a success clears it too.
        t.service.act("wifi on", System.wifiRadio(true), "wifi.act");
        compare(t.service.errors["wifi.act"], undefined);
        t.backend.failed("wifi.act", "");
        compare(t.service.errors["wifi.act"], "-");
        t.backend.finished("wifi.act", true, "");
        compare(t.service.errors["wifi.act"], undefined);
        // A failed query is not an action error.
        t.backend.failed("wifi.list", "boom");
        compare(t.service.errors["wifi.list"], undefined);
    }

    function test_bluetoothRefreshKeepsRows() {
        const t = makeService(false);
        const page = openPage("BluetoothPage.qml", t);
        t.backend.finished("bt.show", true, "Controller AA:BB:CC:DD:EE:FF (public)\n\tPowered: yes\n");
        t.backend.finished("bt.paired", true, "Device 11:22:33:44:55:66 Headphones\nDevice 77:88:99:AA:BB:CC Zed\n");
        t.backend.finished("bt.connected", true, "");
        const zed = rowByTitle(page, "Zed");
        verify(zed && rowByTitle(page, "Headphones"));
        zed.forceActiveFocus();
        verify(zed.activeFocus);
        t.backend.finished("bt.connected", true, "Device 77:88:99:AA:BB:CC Zed\n");
        verify(rowByTitle(page, "Zed") === zed, "row rebuilt");
        verify(zed.activeFocus, "focus lost on refresh");
        compare(zed.subtitle, "Connected");
        compare(rowsOf(page, []).length, 2);
    }

    function test_soundRefreshKeepsRowsAndUsesMicrophone() {
        const t = makeService(false);
        const page = openPage("SoundPage.qml", t);
        t.backend.finished("audio.status", true, wpctlStatus);
        const hdmi = rowByTitle(page, "HDMI [Main]");
        verify(hdmi);
        hdmi.forceActiveFocus();
        verify(hdmi.activeFocus);
        // Volume moved, HDMI became the default, a new source appeared.
        t.backend.finished("audio.status", true, wpctlStatus.replace("[vol: 0.40]", "[vol: 0.30]").replace(" │      55. HDMI [Main]                         [vol: 1.00 MUTED]", " │  *   55. HDMI [Main]                         [vol: 1.00 MUTED]").replace(" │  *   52.", " │      52."));
        verify(rowByTitle(page, "HDMI [Main]") === hdmi, "row rebuilt");
        verify(hdmi.activeFocus, "focus lost on refresh");
        compare(hdmi.checked, true);
        const mics = rowsOf(page, []).filter(r => r.leading === "microphone");
        compare(mics.length, 1);
        compare(rowsOf(page, []).filter(r => r.leading === "volume-1" && r.actionText === "").length, 0);
    }
}
