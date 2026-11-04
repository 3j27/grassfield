import QtQuick
import QtTest
import "../../apps/settings/qml/Setups.js" as Setups
import "../../apps/settings/qml/NetworkQr.js" as NetworkQr
import "../../apps/settings/qml" as SettingsQml

// ADR-0045 (OC-5, OC-7 to OC-10): the commands Settings launches in Omarchy's terminal (checked against the C++ guard's own list),
// the parsers of Remote Login's, Disk Encryption's, Hibernation's and Share Network's answers, then the panes and sheets over a
// fake backend: what they read, which action or launch they start, the passwords emptied, and nothing in a dev session.
TestCase {
    id: testCase
    name: "SettingsSetups"
    width: 700
    height: 900
    visible: true
    when: windowShown

    // lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINTS on Omarchy's layout: the root file system on a LUKS partition.
    readonly property string lsblkLuks: JSON.stringify({blockdevices: [
            {name: "nvme0n1", type: "disk", fstype: null, mountpoints: [null], children: [
                    {name: "nvme0n1p1", type: "part", fstype: "vfat", mountpoints: ["/boot"]},
                    {name: "nvme0n1p2", type: "part", fstype: "crypto_LUKS", mountpoints: [null], children: [
                            {name: "root", type: "crypt", fstype: "btrfs", mountpoints: ["/var/log", "/home", "/"]}]}]},
            {name: "zram0", type: "disk", fstype: "swap", mountpoints: ["[SWAP]"]}]})
    readonly property string lsblkPlain: JSON.stringify({blockdevices: [
            {name: "sda", type: "disk", fstype: null, mountpoints: [null], children: [
                    {name: "sda1", type: "part", fstype: "vfat", mountpoints: ["/boot"]},
                    {name: "sda2", type: "part", fstype: "ext4", mountpoints: ["/"]}]}]})

    // An omarchy-network-qr --meta answer: the meta line, then a square of 0 and 1 (29 modules: a version 1 code with its quiet
    // zone; the pattern does not matter to the parser).
    function qrText(ssid, size) {
        const n = size === undefined ? 29 : size;
        const rows = [];
        for (let y = 0; y < n; y++) {
            let r = "";
            for (let x = 0; x < n; x++)
                r += (x + y) % 3 === 0 ? "1" : "0";
            rows.push(r);
        }
        return "meta\twlan0\tWPA\t" + ssid + "\n" + rows.join("\n") + "\n";
    }

    function readRepo(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        return xhr.responseText;
    }

    function test_launchesAreTheGuardsExactly() {
        const guard = readRepo("apps/settings/src/systemguard.cpp");
        for (const id in Setups.TERMINAL) {
            const argv = Setups.launchArgv(id);
            compare(argv, ["omarchy-launch-floating-terminal-with-presentation", Setups.TERMINAL[id]], id);
            verify(guard.indexOf("QStringLiteral(\"" + Setups.TERMINAL[id] + "\")") >= 0, id + ": in systemguard.cpp's inTerminal list");
        }
        compare(Setups.launchArgv("dictation-model"), ["omarchy-voxtype-model"]);
        verify(guard.indexOf("QStringList{QStringLiteral(\"omarchy-voxtype-model\")}") >= 0);
        compare(Setups.launchArgv("sshd-remove"), null, "Remote Login's switch is systemd's: Omarchy's removal is never launched");
        compare(Setups.launchArgv("constructor"), null);
        compare(Setups.launchArgv(""), null);
        // Each read-only query is one of the guard's.
        for (const k in Setups.QUERY)
            verify(guard.indexOf("\"" + Setups.QUERY[k][0] + "\"") >= 0, k);
        compare(Setups.QUERY.networkQr, ["omarchy-network-qr", "--meta"]);
        compare(Setups.QUERY.blockDevices, ["lsblk", "-J", "-o", "NAME,TYPE,FSTYPE,MOUNTPOINTS"]);
    }

    function test_remoteLogin() {
        compare(Setups.parseSharing(JSON.stringify({installed: true, unitFileState: "enabled", active: true})), {installed: true, enabled: true, active: true});
        compare(Setups.parseSharing(JSON.stringify({installed: true, unitFileState: "disabled", active: false})).enabled, false);
        compare(Setups.parseSharing(JSON.stringify({installed: true, unitFileState: "masked"})).enabled, false);
        compare(Setups.parseSharing("{}"), null);
        compare(Setups.parseSharing("nope"), null);
        const absent = {installed: false, enabled: false, active: false};
        const off = {installed: true, enabled: false, active: false};
        const on = {installed: true, enabled: true, active: true};
        compare(Setups.remoteLoginRoute(null, true, true), "", "not known yet: nothing");
        compare(Setups.remoteLoginRoute(absent, false, true), "terminal", "OpenSSH missing: Omarchy's setup installs it");
        compare(Setups.remoteLoginRoute(absent, true, true), "terminal");
        compare(Setups.remoteLoginRoute(off, false, true), "terminal", "never set up by Omarchy: no key, the firewall closed");
        compare(Setups.remoteLoginRoute(off, true, true), "native");
        compare(Setups.remoteLoginRoute(on, false, false), "native", "turning off is always systemd's");
        compare(Setups.sshCommand("chapdel", "chapdels-laptop"), "ssh chapdel@chapdels-laptop");
        compare(Setups.sshCommand("chapdel", ""), "");
        compare(Setups.sshCommand("", "host"), "");
        compare(Setups.sshCommand("a b", "host"), "");
        compare(Setups.sshCommand("chapdel", "host\nx"), "");
    }

    function test_diskEncryption() {
        compare(Setups.rootEncryption(testCase.lsblkLuks), {known: true, encrypted: true, device: "nvme0n1p2"});
        compare(Setups.rootEncryption(testCase.lsblkPlain), {known: true, encrypted: false, device: ""});
        // An older lsblk names the column MOUNTPOINT (one value).
        const old = JSON.stringify({blockdevices: [{name: "sda2", fstype: "crypto_LUKS", children: [{name: "root", fstype: "ext4", mountpoint: "/"}]}]});
        compare(Setups.rootEncryption(old).encrypted, true);
        compare(Setups.rootEncryption(JSON.stringify({blockdevices: [{name: "sda1", fstype: "ext4", mountpoints: ["/home"]}]})).known, false, "no root: unknown");
        compare(Setups.rootEncryption("nope").known, false);
        compare(Setups.rootEncryption("{}").known, false);
        compare(Setups.parseDisk(JSON.stringify({encrypted: true, device: "/dev/nvme0n1p2"})), {encrypted: true, device: "/dev/nvme0n1p2"});
        compare(Setups.parseDisk("{}"), null);
        compare(Setups.passwordRoute({encrypted: true, device: ""}), "native");
        compare(Setups.passwordRoute({encrypted: false, device: ""}), "terminal", "UDisks2 did not find it: Omarchy's terminal");
        compare(Setups.passwordRoute(null), "terminal", "UDisks2 did not answer");
        verify(Setups.passwordsReady("old", "new pass", "new pass"));
        verify(!Setups.passwordsReady("", "new", "new"), "the current password first");
        verify(!Setups.passwordsReady("old", "new", "New"), "the two new ones the same");
        verify(!Setups.passwordsReady("old", "", ""));
        verify(!Setups.passwordsReady("old", "a".repeat(513), "a".repeat(513)), "at most 512 characters");
        verify(!Setups.passwordsReady("old", "a\u0000b", "a\u0000b"));
    }

    function test_hibernation() {
        compare(Setups.hibernationState(false, true, "HOOKS+=(resume)\n", true), "unsupported", "the kernel cannot hibernate");
        compare(Setups.hibernationState(true, false, "", false), "unsupported", "Omarchy's setup is not there");
        compare(Setups.hibernationState(true, true, "", false), "off");
        compare(Setups.hibernationState(true, true, "HOOKS+=(resume)\n", true), "on");
        compare(Setups.hibernationState(true, true, "HOOKS+=(resume)\n", false), "incomplete");
        compare(Setups.hibernationState(true, true, "# HOOKS+=(resume)\n", false), "off");
    }

    // Omarchy's PAM edits, as its setups write them (the clamshell gate first, then the module).
    function test_whereEachIsUsed() {
        const sudo = "auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed\nauth      sufficient pam_fprintd.so\n"
            + "auth    sufficient pam_u2f.so cue authfile=/etc/fido2/fido2\n#%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\n";
        const polkit = "auth      sufficient pam_fprintd.so\nauth      required pam_unix.so\n# auth sufficient pam_u2f.so\n";
        compare(Setups.fingerprintUse(sudo, polkit, true), {lock: true, admin: true, sudo: true});
        compare(Setups.fingerprintUse("", "", false), {lock: false, admin: false, sudo: false});
        compare(Setups.securityKeyUse(sudo, polkit), {lock: false, admin: false, sudo: true}, "a commented line counts for nothing");
        verify(Setups.anyUse({lock: false, admin: false, sudo: true}));
        verify(!Setups.anyUse(Setups.fingerprintUse("auth sufficient pam_fprintd.so.bak", "", false)));
    }

    function test_networkQr() {
        const code = NetworkQr.parse(testCase.qrText("Café\tBar"));
        verify(code !== null);
        compare(code.iface, "wlan0");
        compare(code.security, "WPA");
        compare(code.ssid, "Café\tBar", "the name is the rest of the meta line, tabs included");
        compare(code.size, 29);
        compare(code.rows.length, 29);
        verify(NetworkQr.matches(code, "Café\tBar"));
        verify(!NetworkQr.matches(code, "Café"));
        verify(!NetworkQr.matches(null, ""));
        compare(NetworkQr.parse(testCase.qrText("x").replace("meta\t", "")), null, "no meta line");
        compare(NetworkQr.parse(testCase.qrText("x").replace("\tWPA\t", "\tWPA2\t")), null);
        compare(NetworkQr.parse(testCase.qrText("x", 28)), null, "smaller than any QR code");
        compare(NetworkQr.parse(testCase.qrText("x", 186)), null);
        compare(NetworkQr.parse(testCase.qrText("x").replace(/\n1/, "\n2")), null, "only 0 and 1");
        const lines = testCase.qrText("x").split("\n");
        lines.splice(3, 1);
        compare(NetworkQr.parse(lines.join("\n")), null, "not square");
        compare(NetworkQr.parse(""), null);
        // Runs: one rectangle per row of dark modules.
        const small = {rows: ["0110", "1001", "0000", "1111"]};
        compare(NetworkQr.runs(small), [{x: 1, y: 0, w: 2}, {x: 0, y: 1, w: 1}, {x: 3, y: 1, w: 1}, {x: 0, y: 3, w: 4}]);
        compare(NetworkQr.runs(null), []);
    }

    // ---- The panes and sheets over a fake backend ----

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property string userName: "chapdel"
            property var pendingActions: ({})
            property var files: ({})
            property var commands: ["voxtype", "omarchy-hibernation-setup", "omarchy-hibernation-available", "omarchy-network-qr"]
            property var busQueries: []
            property var busActions: []
            property var queries: []
            property var launches: []
            // The rest of a page's reads (Keyboard's bindings, layouts; Privacy's applications): nothing.
            property string configFile: "/home/u/.config/grassfield/grassfield.json"
            property string bindingsFile: "/usr/share/grassfield/hypr/grassfield/bindings.lua"
            property var applicationDirs: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal progress(string tag, string status)
            signal suppressed(string what)
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function writeText(path: string, text: string): string {
                return "";
            }
            function hasCommand(name: string): bool {
                return commands.indexOf(name) >= 0;
            }
            function readOnlyQuery(argv: var, tag: string, timeoutMs: int): void {
                queries.push({argv: argv, tag: tag});
            }
            function query(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function busAct(what: string, op: var, tag: string): bool {
                busActions.push({what: what, op: op, tag: tag});
                return true;
            }
            function act(what: string, argv: var, tag: string): bool {
                return true;
            }
            function launch(what: string, argv: var): bool {
                launches.push({what: what, argv: argv});
                return true;
            }
        }
    }

    Component {
        id: serviceComp
        SettingsQml.SystemService {}
    }

    Component {
        id: sharingComp
        SettingsQml.SharingPage {
            anchors.fill: parent
        }
    }

    Component {
        id: terminalComp
        SettingsQml.TerminalSetupSheet {}
    }

    Component {
        id: diskComp
        SettingsQml.DiskPasswordSheet {}
    }

    Component {
        id: shareComp
        SettingsQml.ShareNetworkSheet {}
    }

    Component {
        id: batteryComp
        SettingsQml.BatteryPage {
            anchors.fill: parent
        }
    }

    Component {
        id: privacyComp
        SettingsQml.PrivacyPage {
            anchors.fill: parent
        }
    }

    Component {
        id: keyboardComp
        SettingsQml.KeyboardPage {
            anchors.fill: parent
        }
    }

    Component {
        id: storeComp
        QtObject {
            property var values: ({"keyboard.dictation": false, "keyboard.shortcutStyle": "pc", "keyboard.showInputMenu": true})
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function set(key: string, v: var): void {
                writes.push({key: key, value: v});
                const next = Object.assign({}, values);
                next[key] = v;
                values = next;
            }
        }
    }

    function service(dev, files) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev === true, files: files || {}});
        const system = createTemporaryObject(serviceComp, testCase, {backend: backend});
        return {backend: backend, system: system};
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

    function test_sharingPane() {
        const s = service(false, {});
        const page = createTemporaryObject(sharingComp, testCase, {backend: s.backend, system: s.system});
        verify(page);
        compare(s.backend.busQueries.map(q => q.what), ["sharing.state", "host.state"]);
        s.backend.finished("sharing.host", true, JSON.stringify({hostname: "chapdels-laptop"}));
        s.backend.finished("sharing.state", true, JSON.stringify({installed: true, unitFileState: "disabled", active: false}));
        verify(!page.on);
        const asked = [];
        page.setupRequested.connect(id => asked.push(id));
        // Never set up by Omarchy (no hardening file): its setup in the terminal, nothing sent to systemd.
        page.setRemoteLogin(true);
        compare(asked, ["sshd-setup"]);
        compare(s.backend.busActions.length, 0);
        // Set up: systemd's switch.
        s.backend.files = {"/etc/ssh/sshd_config.d/10-omarchy-hardening.conf": "PasswordAuthentication no\n"};
        page.refresh();
        page.setRemoteLogin(true);
        compare(s.backend.busActions[0].op, {op: "ssh.enable", on: true});
        compare(s.backend.busActions[0].tag, "sharing.act");
        s.backend.finished("sharing.state", true, JSON.stringify({installed: true, unitFileState: "enabled", active: true}));
        verify(page.on);
        compare(page.sshLine, "ssh chapdel@chapdels-laptop");
        // A dev session sends nothing.
        const d = service(true, {"/etc/ssh/sshd_config.d/10-omarchy-hardening.conf": "x"});
        const devPage = createTemporaryObject(sharingComp, testCase, {backend: d.backend, system: d.system});
        d.backend.finished("sharing.state", true, JSON.stringify({installed: true, unitFileState: "disabled", active: false}));
        devPage.setRemoteLogin(true);
        compare(d.backend.busActions.length, 0);
        verify(d.system.suppressedNote);
    }

    function test_terminalSheet() {
        const s = service(false, {});
        const sheet = createTemporaryObject(terminalComp, testCase, {system: s.system});
        const launched = [];
        sheet.launched.connect(id => launched.push(id));
        sheet.openFor("hibernation-setup");
        verify(sheet.shown);
        compare(sheet.title, "Set Up Hibernation");
        verify(sheet.message.indexOf("Terminal") >= 0, "it says why a terminal opens");
        sheet.confirm();
        compare(s.backend.launches, [{what: "hibernation-setup", argv: ["omarchy-launch-floating-terminal-with-presentation", "omarchy-hibernation-setup"]}]);
        compare(launched, ["hibernation-setup"]);
        // Cancel launches nothing; an unknown id opens nothing.
        sheet.openFor("dictation-model");
        sheet.cancel();
        compare(s.backend.launches.length, 1);
        sheet.openFor("bogus");
        verify(!sheet.shown);
        for (const id in Setups.TERMINAL)
            verify(sheet.texts[id] !== undefined && sheet.texts[id].message !== "", id);
        const d = service(true, {});
        const devSheet = createTemporaryObject(terminalComp, testCase, {system: d.system});
        devSheet.openFor("dictation-setup");
        devSheet.confirm();
        compare(d.backend.launches.length, 0);
    }

    function test_diskPasswordSheet() {
        const s = service(false, {});
        const sheet = createTemporaryObject(diskComp, testCase, {system: s.system, backend: s.backend});
        sheet.openSheet();
        const fields = [];
        const collect = item => {
            if (item.echoMode !== undefined && item.placeholderText !== undefined && item.visible && item.accessibleName !== "Change the start-up disk's password")
                fields.push(item);
            for (let i = 0; i < (item.children || []).length; i++)
                collect(item.children[i]);
        };
        collect(sheet);
        // The Sheet's own field is hidden (withField false): the three of the body.
        compare(fields.length, 3);
        fields[0].text = "old secret";
        fields[1].text = "new secret";
        fields[2].text = "new secreT";
        verify(!sheet.confirmEnabled, "the two new ones differ");
        fields[2].text = "new secret";
        verify(sheet.confirmEnabled);
        sheet.confirm();
        compare(s.backend.busActions[0].op, {op: "disk.passphrase", old: "old secret", new: "new secret"});
        compare(s.backend.busActions[0].tag, "disk.act");
        compare(fields.map(f => f.text), ["", "", ""], "emptied as soon as the request is built");
        verify(sheet.shown, "open until the service answers");
        s.backend.failed("disk.act", "the current password is not correct");
        s.backend.finished("disk.act", false, "");
        compare(sheet.errorText, "The password was not changed: the current password is not correct.");
        verify(sheet.shown);
        fields[0].text = "a";
        sheet.cancel();
        compare(fields[0].text, "", "Cancel empties them");
        sheet.openSheet();
        fields[0].text = "x";
        fields[1].text = "y";
        fields[2].text = "y";
        sheet.confirm();
        s.backend.finished("disk.act", true, "");
        verify(!sheet.shown, "closed once changed");
    }

    function test_shareNetworkSheet() {
        const s = service(false, {});
        const sheet = createTemporaryObject(shareComp, testCase, {backend: s.backend});
        const net = {ssid: "Café\tBar", label: "Café Bar", active: true, enterprise: false};
        sheet.openFor(net);
        compare(s.backend.queries[0], {argv: ["omarchy-network-qr", "--meta"], tag: "wifi.qr"});
        verify(sheet.loading);
        s.backend.finished("wifi.qr", true, testCase.qrText("Café\tBar"));
        verify(sheet.code !== null);
        verify(sheet.cells.length > 0);
        verify(sheet.message.indexOf("password") >= 0, "it says the code holds the password; it never shows it");
        sheet.close();
        compare(sheet.code, null, "the matrix (it encodes the password) is dropped on close");
        sheet.openFor(net);
        s.backend.finished("wifi.qr", true, testCase.qrText("Neighbour"));
        compare(sheet.code, null, "a code made for another network is not drawn");
        compare(sheet.error, "The code was made for another network.");
        sheet.openFor(net);
        s.backend.failed("wifi.qr", "Enterprise Wi-Fi cannot be shared with a password QR code");
        s.backend.finished("wifi.qr", false, "");
        compare(sheet.code, null);
        compare(sheet.error, "Enterprise Wi-Fi cannot be shared with a password QR code");
    }

    function test_batteryHibernation() {
        const s = service(false, {"/sys/power/image_size": "6537345024\n"});
        const page = createTemporaryObject(batteryComp, testCase, {backend: s.backend, system: s.system});
        compare(page.hibernation, "off");
        verify(s.backend.queries.some(q => q.tag === "power.hibernation" && q.argv[0] === "omarchy-hibernation-available"));
        const asked = [];
        page.setupRequested.connect(id => asked.push(id));
        s.backend.finished("power.hibernation", true, "");
        compare(page.hibernation, "on");
        s.backend.files = {"/sys/power/image_size": "1\n", "/etc/mkinitcpio.conf.d/omarchy_resume.conf": "HOOKS+=(resume)\n"};
        s.backend.finished("power.hibernation", false, "");
        compare(page.hibernation, "incomplete");
        // No image_size: no group.
        const n = service(false, {});
        const none = createTemporaryObject(batteryComp, testCase, {backend: n.backend, system: n.system});
        compare(none.hibernation, "unsupported");
        verify(!n.backend.queries.some(q => q.tag === "power.hibernation"));
    }

    function test_privacyDiskEncryption() {
        const s = service(false, {});
        const page = createTemporaryObject(privacyComp, testCase, {backend: s.backend, system: s.system});
        verify(s.backend.queries.some(q => q.tag === "privacy.disk" && q.argv.join(" ") === "lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINTS"));
        verify(s.backend.busQueries.some(q => q.what === "disk.state"));
        s.backend.finished("privacy.disk", true, testCase.lsblkLuks);
        compare(page.encryption, {known: true, encrypted: true, device: "nvme0n1p2"});
        let native = 0;
        const asked = [];
        page.diskPasswordRequested.connect(() => native++);
        page.setupRequested.connect(id => asked.push(id));
        const button = find(page, i => i.text === "Change Password…" && i.push !== undefined);
        verify(button);
        // UDisks2 has not answered (or did not): Omarchy's terminal.
        button.clicked();
        compare(asked, ["drive-password"]);
        s.backend.finished("privacy.udisks", true, JSON.stringify({encrypted: true, device: "/dev/nvme0n1p2"}));
        button.clicked();
        compare(native, 1);
        s.backend.finished("privacy.disk", true, testCase.lsblkPlain);
        verify(!page.encryption.encrypted);
        verify(!button.visible, "no button to turn it on: it cannot be done in place");
    }

    function test_keyboardDictation() {
        const s = service(false, {});
        s.backend.commands = [];
        const store = createTemporaryObject(storeComp, testCase);
        const page = createTemporaryObject(keyboardComp, testCase, {backend: s.backend, store: store});
        verify(!page.voxtype);
        const asked = [];
        page.setupRequested.connect(id => asked.push(id));
        const setUp = find(page, i => i.text === "Set Up…" && i.push !== undefined);
        verify(setUp && setUp.visible);
        setUp.clicked();
        compare(asked, ["dictation-setup"]);
        const toggle = find(page, i => i.accessibleName === "Dictation" && i.toggled !== undefined);
        verify(!toggle.enabled, "no switch without voxtype");
        // Installed meanwhile in the terminal: found when Settings is active again.
        s.backend.commands = ["voxtype"];
        page.voxtype = s.backend.hasCommand("voxtype");
        verify(toggle.enabled);
        toggle.toggled(true);
        compare(store.writes, [{key: "keyboard.dictation", value: true}]);
        const shortcut = find(page, i => i.title === "Shortcut" && i.valueText !== undefined);
        compare(shortcut.valueText, "Ctrl+Super+X");
        find(page, i => i.text === "Language Model…" && i.push !== undefined).clicked();
        find(page, i => i.text === "Remove…" && i.push !== undefined).clicked();
        compare(asked, ["dictation-setup", "dictation-model", "dictation-remove"]);
    }
}
