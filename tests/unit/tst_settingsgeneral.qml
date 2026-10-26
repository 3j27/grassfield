import QtQuick
import QtTest
import "../../apps/settings/qml/General.js" as General

// The pure logic of Settings > General's sub-panes (apps/settings/qml/General.js): the D-Bus states, the action maps the
// Backend checks again (systembus.cpp), command output, desktop entries. Nothing here touches the machine.
TestCase {
    name: "SettingsGeneral"

    function test_hostState() {
        const h = General.parseHost('{"pretty":"Chapdel’s Laptop","static":"chapdels-laptop","hostname":"x","chassis":"laptop","vendor":"LENOVO","model":"ThinkPad X1 Carbon Gen 11"}');
        compare(h.pretty, "Chapdel’s Laptop");
        compare(General.computerName(h), "Chapdel’s Laptop");
        compare(General.computerName({pretty: "", "static": "box", hostname: "t"}), "box");
        compare(General.computerName({pretty: "", "static": "", hostname: "t"}), "t");
        compare(General.parseHost("[]"), null);
        compare(General.parseHost("nope"), null);
        // Strings only: a number or an object becomes "".
        compare(General.parseHost('{"pretty":3,"model":{}}').pretty, "");
    }

    function test_modelName() {
        compare(General.modelName({vendor: "LENOVO", model: "ThinkPad X1 Carbon Gen 11"}), "LENOVO ThinkPad X1 Carbon Gen 11");
        compare(General.modelName({vendor: "Framework", model: "Framework Laptop 13"}), "Framework Laptop 13");
        compare(General.modelName({vendor: "Apple Inc.", model: "MacBookPro18,3"}), "Apple Inc. MacBookPro18,3");
        compare(General.modelName({vendor: "System manufacturer", model: "System Product Name"}), "");
        compare(General.modelName({vendor: "ASUS", model: "To Be Filled By O.E.M."}), "ASUS");
        compare(General.modelName(null), "");
    }

    function test_deviceKind() {
        compare(General.deviceKind("laptop"), "laptop");
        compare(General.deviceKind("convertible"), "laptop");
        compare(General.deviceKind("desktop"), "desktop");
        compare(General.deviceKind("vm"), "desktop");
        compare(General.deviceKind(""), "desktop");
    }

    function test_rename() {
        compare(General.hostSetName("  Grassfield Reference "), {op: "host.setName", name: "Grassfield Reference"});
        compare(General.hostSetName(""), null);
        compare(General.hostSetName("   "), null);
        compare(General.hostSetName("a\nb"), null);
        compare(General.hostSetName("x".repeat(65)), null);
        verify(General.hostSetName("x".repeat(64)) !== null);
    }

    function test_diagonal() {
        compare(General.diagonalInches(302, 188), 14);
        compare(General.diagonalInches(286, 179), 13.3);
        compare(General.diagonalInches(0, 188), 0);
        compare(General.diagonalInches(undefined, undefined), 0);
    }

    function test_storage() {
        const du = General.parseDu("18400000000\t/home/u/Documents\n41700000000\t/home/u/Pictures\ndu: cannot read\n");
        compare(du["/home/u/Documents"], 18400000000);
        compare(du["/home/u/Pictures"], 41700000000);
        compare(General.packagesBytes("Name : a\nInstalled Size  : 1.50 GiB\nInstalled Size  : 512.00 KiB\nInstalled Size  : 10 B\n"), Math.round(1.5 * 1073741824 + 512 * 1024 + 10));
        compare(General.packagesBytes(""), 0);
        const argv = General.duArgv("/home/u");
        compare(argv.slice(0, 5), ["du", "-s", "-x", "--block-size=1", "--"]);
        compare(argv.length, 5 + 7);
        verify(argv.slice(5).every(p => p.indexOf("/home/u/") === 0));
        const volume = {total: 1000, available: 400};
        const cats = General.categories(volume, {"/home/u/Documents": 100, "/home/u/Pictures": 250}, 150, "/home/u");
        compare(cats.map(c => c.id), ["pictures", "applications", "documents", "system"]);
        compare(cats[3].bytes, 600 - 500);
        // What is counted never makes System negative.
        compare(General.categories({total: 100, available: 90}, {"/home/u/Documents": 50}, 0, "/home/u").pop().bytes, 0);
        compare(General.categories(null, {}, 0, "/home/u"), []);
    }

    function test_time() {
        const t = General.parseTime('{"zone":"Europe/Paris","ntp":true,"canNtp":true,"synced":false,"localRtc":false,"usec":"1792832460123456","server":"a","servers":["a","b",3]}');
        compare(t.zone, "Europe/Paris");
        verify(t.ntp);
        compare(t.servers, ["a", "b"]);
        compare(General.msOf(t), 1792832460123);
        compare(General.parseTime('{"usec":"12; rm"}').usec, "0");
        compare(General.parseZones('{"zones":["Europe/Paris","../x","UTC"]}'), ["Europe/Paris", "UTC"]);
        compare(General.cityOf("America/Argentina/Buenos_Aires"), "Buenos Aires");
        compare(General.areaOf("Europe/Paris"), "Europe");
        compare(General.cityOf("UTC"), "UTC");
        compare(General.areaOf("UTC"), "");
        const zones = ["Europe/Zurich", "America/New_York", "Europe/Paris", "Asia/Tokyo", "Pacific/Port_Moresby"];
        compare(General.cityMatches(zones, "zur", 5), ["Europe/Zurich"]);
        compare(General.cityMatches(zones, "Zür", 5), ["Europe/Zurich"]);
        compare(General.cityMatches(zones, "new y", 5), ["America/New_York"]);
        compare(General.cityMatches(zones, "or", 5), ["America/New_York", "Pacific/Port_Moresby"]);
        compare(General.cityMatches(zones, "  ", 5), []);
        compare(General.timeNtp(true), {op: "time.ntp", on: true});
        compare(General.timeNtp("yes"), null);
        compare(General.timeZone("Europe/Paris"), {op: "time.zone", zone: "Europe/Paris"});
        compare(General.timeZone("../../etc/passwd"), null);
        compare(General.timeZone("Europe/Paris\n"), null);
        compare(General.timeSet(1792832460123.9), {op: "time.set", usec: "1792832460123000"});
        compare(General.timeSet(0), null);
        compare(General.timeSet(NaN), null);
    }

    function test_language() {
        const list = General.parseLanguages("English\ten\tEnglish\nFrançais\tfr\tFrench\nbad line\nX\tFR\tbad\n中文 (简体)\tzh-CN\tChinese (Simplified)\n");
        compare(list.length, 3);
        compare(list[1], {name: "Français", code: "fr", english: "French"});
        compare(list[2].code, "zh-CN");
        compare(General.currentLanguage("fr\n"), "fr");
        compare(General.currentLanguage("fr; rm\n"), "");
        compare(General.languageArgv("fr"), ["omarchy-language", "fr"]);
        compare(General.languageArgv("--help"), null);
        compare(General.languageArgv("fr\n"), null);
    }

    function test_desktopEntries() {
        const text = "[Desktop Entry]\nType=Application\nName=Syncthing\nName[fr]=Syncthing (fr)\nExec=syncthing\nIcon=syncthing\nOnlyShowIn=GNOME;Hyprland;\n[Desktop Action x]\nName=Other\n";
        const e = General.parseDesktopEntry(text, "fr_FR.UTF-8");
        compare(e.name, "Syncthing (fr)");
        compare(e.exec, "syncthing");
        compare(e.onlyShowIn, ["GNOME", "Hyprland"]);
        compare(General.parseDesktopEntry(text, "de").name, "Syncthing");
        verify(General.startsHere(e, ["Hyprland"]));
        verify(!General.startsHere(e, ["KDE"]));
        verify(!General.startsHere(General.parseDesktopEntry("[Desktop Entry]\nName=a\nHidden=true\n", ""), ["Hyprland"]));
        verify(!General.startsHere(General.parseDesktopEntry("[Desktop Entry]\nName=a\nX-GNOME-Autostart-enabled=false\n", ""), ["Hyprland"]));
        verify(!General.startsHere(General.parseDesktopEntry("[Desktop Entry]\nName=a\nNotShowIn=Hyprland;\n", ""), ["Hyprland"]));
    }

    function test_loginItems() {
        const system = [
            {file: "fcitx.desktop", text: "[Desktop Entry]\nName=Fcitx 5\nIcon=fcitx\n"},
            {file: "applet.desktop", text: "[Desktop Entry]\nName=Print Applet\n"},
            {file: "gnome-only.desktop", text: "[Desktop Entry]\nName=GNOME thing\nOnlyShowIn=GNOME;\n"}
        ];
        const user = [
            {file: "applet.desktop", text: "[Desktop Entry]\nHidden=true\n"},
            {file: "notes.desktop", text: "[Desktop Entry]\nName=Notes\nExec=notes\n"}
        ];
        const items = General.loginItems(user, system, ["Hyprland"], "en");
        compare(items.map(i => i.name), ["Fcitx 5", "Notes", "Print Applet"]);
        const applet = items.filter(i => i.file === "applet.desktop")[0];
        verify(!applet.enabled);
        verify(applet.user && applet.system);
        verify(items.filter(i => i.file === "notes.desktop")[0].enabled);
        verify(General.validEntryFile("notes.desktop"));
        verify(!General.validEntryFile("../notes.desktop"));
        verify(!General.validEntryFile("notes.desktop\n"));
        verify(!General.validEntryFile("notes"));
        compare(General.hiddenEntryText(), "[Desktop Entry]\nType=Application\nHidden=true\n");
        const copy = General.loginEntryText("[Desktop Entry]\nName=App\nExec=app\nHidden=true\nOnlyShowIn=GNOME;\n[Desktop Action n]\nOnlyShowIn=x\n");
        compare(copy, "[Desktop Entry]\nName=App\nExec=app\n[Desktop Action n]\nOnlyShowIn=x\n");
    }

    function test_userUnits() {
        compare(General.userEnable("sync.service", false), {op: "user.enable", unit: "sync.service", on: false});
        compare(General.userEnable("sync.timer", true), null);
        compare(General.userEnable("../x.service", true), null);
        compare(General.userEnable("x.service", "on"), null);
        compare(General.parseUnits('{"units":[{"unit":"a.service","path":"/p","state":"enabled"},{"unit":3}]}').length, 1);
        compare(General.parseUnits("x"), []);
    }
}
