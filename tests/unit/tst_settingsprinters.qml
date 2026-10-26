import QtQuick
import QtTest
import "../../apps/settings/qml/Printers.js" as Printers

// Settings > Printers (ADR-0026): CUPS's output as `lpstat` and `lpoptions` print it in the C locale, the ops and commands the pane
// may send (the C++ guard checks them again, tests/unit/settings/tst_systemguard.cpp), and the pane: what it reads, the paper
// size written only to the queues that have it, Add and Remove through SystemService, nothing in a dev session.
TestCase {
    id: testCase
    name: "SettingsPrinters"
    width: 700
    height: 900
    visible: true
    when: windowShown

    readonly property string listing: "printer GF_Office is idle.  enabled since Mon 26 Oct 2026 09:00:00 AM CET\n"
        + "\tForm mounted:\n\tContent types: any\n\tPrinter types: unknown\n\tDescription: GF Office Laser\n\tAlerts: none\n"
        + "\tLocation: Studio\n\tConnection: direct\n\tInterface: /etc/cups/ppd/GF_Office.ppd\n\tOn fault: no alert\n"
        + "printer Label now printing Label-12.  enabled since Mon 26 Oct 2026 09:00:00 AM CET\n\tDescription: \n\tLocation: \n"
        + "printer Old disabled since Mon 26 Oct 2026 09:00:00 AM CET -\n\tUnplugged or turned off\n\tForm mounted:\n\tDescription: Old Inkjet\n"
        + "printer Hold is holding new jobs.  enabled since Mon 26 Oct 2026 09:00:00 AM CET\n"
        + "printer Old/draft disabled since Mon 26 Oct 2026 09:00:00 AM CET -\n\treason unknown\n"

    function test_parsePrinters() {
        const p = Printers.parsePrinters(testCase.listing);
        compare(p.map(x => x.name), ["GF_Office", "Label", "Old", "Hold"]);
        compare(p.map(x => x.state), ["idle", "printing", "stopped", "holding"]);
        compare(p[0].description, "GF Office Laser");
        compare(p[0].location, "Studio");
        compare(p[0].message, "");
        compare(p[1].description, "");
        // The line right under a stopped printer is its message; the long listing's keys never are.
        compare(p[2].message, "Unplugged or turned off");
        compare(p[2].description, "Old Inkjet");
        compare(Printers.parsePrinters(""), []);
        compare(Printers.parsePrinters("lpstat: No destinations added.\n"), []);
    }

    function test_parseDefaultDevicesAndFound() {
        compare(Printers.parseDefault("system default destination: GF_Office\n"), "GF_Office");
        compare(Printers.parseDefault("system default destination: GF_Office/draft\n"), "GF_Office");
        compare(Printers.parseDefault("no system default destination\n"), "");
        compare(Printers.parseDevices("device for GF_Office: ipp://192.0.2.7/ipp/print\ndevice for Usb: usb://Brother/HL?serial=1\n"),
            {GF_Office: "ipp://192.0.2.7/ipp/print", Usb: "usb://Brother/HL?serial=1"});
        const found = Printers.parseFound("GF_Office permanent ipp://localhost/printers/GF_Office implicitclass://GF_Office/\n"
            + "GF_Studio network none dnssd://GF%20Studio._ipp._tcp.local/?uuid=0f1e\n"
            + "Temp temporary ipp://localhost/printers/Temp dnssd://Temp._ipp._tcp.local/\n"
            + "Bad_Uri network none socket://192.0.2.9\n"
            + "-x network none ipp://192.0.2.9/ipp/print\n"
            + "Taken network none ipp://192.0.2.10/ipp/print\n"
            + "Null network none (null)\n"
            + "GF_Studio network none dnssd://GF%20Studio._ipp._tcp.local/?uuid=0f1e\n", [{name: "Taken"}]);
        // Only printers that are not queues yet, with a URI cupsd makes a driverless queue of, once each.
        compare(found, [{name: "GF_Studio", uri: "dnssd://GF%20Studio._ipp._tcp.local/?uuid=0f1e"}]);
    }

    function test_paper() {
        const p = Printers.parsePaper("PageSize/Media Size: Letter Legal *A4 A5 Env10 Custom.WIDTHxHEIGHT\nDuplex/2-Sided Printing: *None\n");
        compare(p.current, "A4");
        compare(p.choices, ["Letter", "Legal", "A4", "A5", "Env10"]);
        // The common sizes the printer has, in the order of the list, and the one in effect when it is another.
        compare(Printers.paperChoices(p), ["Letter", "Legal", "A4", "A5"]);
        compare(Printers.paperChoices({choices: ["Env10", "A4"], current: "Env10"}), ["A4", "Env10"]);
        compare(Printers.parsePaper("Duplex/2-Sided Printing: *None\n"), {choices: [], current: ""});
    }

    function test_opsAndCommands() {
        compare(Printers.addOp({name: "GF_Studio_Color", uri: "dnssd://x._ipp._tcp.local/"}),
            {op: "printer.add", name: "GF_Studio_Color", uri: "dnssd://x._ipp._tcp.local/", info: "GF Studio Color"});
        compare(Printers.addOp({name: "x", uri: "usb://Brother/HL"}), null);
        compare(Printers.addOp({name: "a b", uri: "ipp://192.0.2.7/ipp/print"}), null);
        compare(Printers.addOp({name: "x", uri: "ipp://host/a b"}), null);
        compare(Printers.addOp(null), null);
        compare(Printers.deleteOp("GF_Office"), {op: "printer.delete", name: "GF_Office"});
        compare(Printers.deleteOp("-E"), null);
        compare(Printers.resumeOp("GF_Office"), {op: "printer.resume", name: "GF_Office"});
        compare(Printers.resumeOp("a b"), null);
        compare(Printers.parseAccepting("GF_Office accepting requests since Mon 26 Oct 2026 09:00:00 AM CET\n"
            + "New not accepting requests since Mon 26 Oct 2026 09:00:00 AM CET -\n\treason unknown\nOld/draft accepting requests since x\n"),
            {GF_Office: true, New: false, Old: true});
        compare(Printers.QUERY.accepting, ["lpstat", "-a"]);
        compare(Printers.setDefault("GF_Office"), ["lpoptions", "-d", "GF_Office"]);
        compare(Printers.setDefault("a/b"), null);
        compare(Printers.setPaper("GF_Office", "A4"), ["lpoptions", "-p", "GF_Office", "-o", "PageSize=A4"]);
        compare(Printers.setPaper("GF_Office", "A4 B5"), null);
        compare(Printers.paperQuery("GF_Office"), ["lpoptions", "-p", "GF_Office", "-l"]);
        compare(Printers.kindOf("implicitclass://GF_Office/"), "driverless");
        compare(Printers.kindOf("usb://Brother/HL"), "usb");
        compare(Printers.kindOf("socket://192.0.2.7"), "network");
        compare(Printers.kindOf(undefined), "other");
        // The reads are exactly the C++ guard's (-l first: lpstat applies it to what follows).
        compare(Printers.QUERY.found, ["lpstat", "-l", "-e"]);
        compare(Printers.QUERY.printers, ["lpstat", "-l", "-p"]);
    }

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property var queries: []
            property var actions: []
            property var busActions: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            function query(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push(argv);
                return true;
            }
            function busAct(what: string, op: var, tag: string): bool {
                busActions.push(op);
                return true;
            }
        }
    }

    function makePage(dev) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev});
        const svc = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/SystemService.qml"));
        compare(svc.status, Component.Ready, svc.errorString());
        const system = createTemporaryObject(svc, testCase, {backend: backend});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/PrintersPage.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {backend: backend, system: system, width: 700, height: 900});
        verify(page);
        return {backend: backend, page: page};
    }

    function test_pageReadsAndActs() {
        const t = makePage(false);
        compare(t.backend.queries.map(q => q.tag), ["printers.list", "printers.default", "printers.devices", "printers.accepting"]);
        t.backend.finished("printers.list", true, testCase.listing);
        t.backend.finished("printers.default", true, "system default destination: GF_Office\n");
        compare(t.page.printers.length, 4);
        // Each queue's paper sizes are read once.
        compare(t.backend.queries.filter(q => q.tag.startsWith("printers.paper:")).map(q => q.argv[2]), ["GF_Office", "Label", "Old", "Hold"]);
        t.backend.finished("printers.paper:GF_Office", true, "PageSize/Media Size: Letter *A4\n");
        t.backend.finished("printers.paper:Label", true, "PageSize/Media Size: *w62h100\n");
        t.backend.finished("printers.paper:Old", true, "PageSize/Media Size: *Letter A4 Legal\n");
        t.backend.finished("printers.paper:Hold", false, "");
        compare(t.page.paper.current, "A4");
        compare(t.page.paperChoices, ["Letter", "A4"]);
        compare(t.page.statusOf(t.page.printers[0]), "Idle, Default");
        compare(t.page.statusOf(t.page.printers[2]), "Stopped");
        // A4 goes to the queues that have it, not to the label printer nor to the one that did not answer.
        t.page.choosePaper("A4");
        compare(t.backend.actions, [["lpoptions", "-p", "GF_Office", "-o", "PageSize=A4"], ["lpoptions", "-p", "Old", "-o", "PageSize=A4"]]);
        t.page.chooseDefault("Old");
        compare(t.backend.actions[2], ["lpoptions", "-d", "Old"]);
        t.page.remove("Old");
        compare(t.backend.busActions, [{op: "printer.delete", name: "Old"}]);
        // After an action: the state and every queue's sizes are read again.
        const before = t.backend.queries.length;
        t.backend.finished("printers.act", true, "");
        compare(t.backend.queries.slice(before).map(q => q.tag), ["printers.list", "printers.default", "printers.devices", "printers.accepting"]);
        compare(t.page.papers, {});
        // Add Printer…: found while searching only, without the queues there already.
        t.page.startSearching();
        compare(t.backend.queries[t.backend.queries.length - 1].argv, ["lpstat", "-l", "-e"]);
        t.backend.finished("printers.found", true, "Old network none ipp://192.0.2.7/ipp/print\nNew_One network none ipp://192.0.2.8/ipp/print\n");
        compare(t.page.found, [{name: "New_One", uri: "ipp://192.0.2.8/ipp/print"}]);
        verify(t.page.foundAnswered);
        t.page.add(t.page.found[0]);
        compare(t.backend.busActions[1], {op: "printer.add", name: "New_One", uri: "ipp://192.0.2.8/ipp/print", info: "New One"});
        t.page.stopSearching();
        t.backend.finished("printers.found", true, "Late network none ipp://192.0.2.9/ipp/print\n");
        compare(t.page.found.length, 1);
        // An added queue whose switches were refused: idle but refusing jobs; its sheet offers Resume, which sends the op.
        t.backend.finished("printers.list", true, testCase.listing);
        t.backend.finished("printers.accepting", true, "GF_Office not accepting requests since x -\n\treason unknown\nLabel accepting requests since x\n");
        compare(t.page.statusOf(t.page.printers[0]), "Not Accepting Jobs, Default");
        verify(t.page.details(t.page.printers[0]).needsResume);
        verify(!t.page.details(t.page.printers[1]).needsResume);
        verify(t.page.details(t.page.printers[2]).needsResume);
        t.page.resume("GF_Office");
        compare(t.backend.busActions[2], {op: "printer.resume", name: "GF_Office"});
    }

    function test_cupsNotAnsweringAndDevSession() {
        const t = makePage(true);
        t.backend.finished("printers.list", false, "");
        verify(t.page.answered && !t.page.available);
        t.backend.finished("printers.list", true, testCase.listing);
        t.page.chooseDefault("GF_Office");
        t.page.remove("GF_Office");
        t.page.add({name: "New_One", uri: "ipp://192.0.2.8/ipp/print"});
        // A dev session reads CUPS but changes nothing.
        compare(t.backend.actions, []);
        compare(t.backend.busActions, []);
    }
}
