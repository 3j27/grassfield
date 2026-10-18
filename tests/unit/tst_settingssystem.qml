import QtQuick
import QtTest
import "../../apps/settings/qml/System.js" as System

// Settings system sections (Wi-Fi, Bluetooth, Sound, Displays): parsers of the tools' output, action argument vectors,
// arrangement, and the dev guard of SystemService (an action never reaches the backend with GRASSFIELD_DEV=1).
TestCase {
    id: testCase
    name: "SettingsSystem"

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property var queries: []
            property var actions: []
            signal finished(string tag, bool ok, string output)
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

    // ---- guard ----

    function test_devGuardSuppressesEveryAction() {
        const t = makeService(true);
        verify(t.service.dev);
        const actions = [
            ["wifi off", System.wifiRadio(false)],
            ["wifi connect", System.wifiConnectKnown("Home")],
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
        compare(System.wifiConnectKnown("Home"), ["nmcli", "connection", "up", "id", "Home"]);
        compare(System.btConnect("aa:bb:cc:dd:ee:ff", false), ["bluetoothctl", "disconnect", "aa:bb:cc:dd:ee:ff"]);
        compare(System.setVolume(52, 1.7), ["wpctl", "set-volume", "52", "1.00"]);
        compare(System.setVolume(52, -1), ["wpctl", "set-volume", "52", "0.00"]);
        compare(System.setMute(52, false), ["wpctl", "set-mute", "52", "0"]);
        compare(System.setDefaultDevice(52), ["wpctl", "set-default", "52"]);
    }

    // ---- Wi-Fi ----

    function test_wifiList() {
        const text = "*:Home\\: 5G:72:WPA2\n" + " :Home\\: 5G:40:WPA2\n" + " :Cafe:55:--\n" + " :Office:90:WPA2 802.1X\n" + " ::30:WPA2\n" + " :Weak:12:WPA3\n";
        const list = System.parseWifiList(text);
        compare(list.map(n => n.ssid), ["Home: 5G", "Office", "Cafe", "Weak"]);
        compare(list[0].active, true);
        compare(list[0].signal, 72);
        compare(list[1].enterprise, true);
        compare(list[2].secured, false);
        compare(list[3].secured, true);
    }

    function test_wifiDuplicateKeepsStrongest() {
        const list = System.parseWifiList(" :Net:30:WPA2\n :Net:80:WPA2\n");
        compare(list.length, 1);
        compare(list[0].signal, 80);
    }

    function test_wifiRadioProfilesDevices() {
        compare(System.parseWifiRadio("enabled\n"), true);
        compare(System.parseWifiRadio("disabled\n"), false);
        compare(System.parseWifiRadio(""), null);
        compare(System.parseWifiProfiles("Home:802-11-wireless\nWired connection 1:802-3-ethernet\nlo:loopback\n"), ["Home"]);
        const dev = System.parseWifiDevice("lo:loopback:connected (externally)\nwlo1:wifi:connected\np2p-dev-wlo1:wifi-p2p:disconnected\n");
        compare(dev.name, "wlo1");
        compare(dev.connected, true);
        compare(System.parseWifiDevice("eno2:ethernet:unavailable\n"), null);
    }

    function test_wifiClickKind() {
        const profiles = ["Home"];
        compare(System.wifiClickKind({ssid: "Home", active: true, secured: true}, profiles), "current");
        compare(System.wifiClickKind({ssid: "Home", active: false, secured: true}, profiles), "known");
        compare(System.wifiClickKind({ssid: "Cafe", active: false, secured: false}, profiles), "open");
        compare(System.wifiClickKind({ssid: "Other", active: false, secured: true}, profiles), "password");
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
}
