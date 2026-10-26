pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Printers.js" as Printers

// Printers as macOS 27 lays out Printers & Scanners (docs/audits/settings-parity-2026-10-26.md § Printers; ADR-0026): Default
// printer and Default paper size, the printers with their state, and Add Printer… under them. CUPS is read with `lpstat` and
// `lpoptions -p <queue> -l` (Printers.js); the two defaults are the user's own (`lpoptions`, ~/.cups/lpoptions, no password);
// adding and removing a printer go to cups-pk-helper, which asks for the administrator's password (polkit). Every change goes
// through SystemService: never in a dev session.
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Main.qml opens the sheets (a printer's details, Add Printer…) and hands the answers back (add, remove, stopSearching).
    signal detailsRequested(var printer)
    signal addRequested

    title: qsTr("Printers")

    property bool answered: false
    property bool available: false
    property var printers: []
    property string defaultName: ""
    property var devices: ({})
    // queue -> whether it accepts jobs (`lpstat -a`; a queue not listed is taken as accepting).
    property var accepting: ({})
    // queue -> {choices, current}: each queue's paper sizes (read once per queue, again after a change).
    property var papers: ({})
    // Add Printer…: what cupsd and DNS-SD find, read while the sheet is open.
    property bool searching: false
    property bool foundAnswered: false
    property var found: []

    readonly property var paper: root.papers[root.defaultName] ?? {choices: [], current: ""}
    readonly property var paperChoices: Printers.paperChoices(root.paper)

    function displayName(printer: var): string {
        return printer.description !== "" ? printer.description : Printers.infoOf(printer.name);
    }

    // Stopped, or refusing new jobs: Resume (in its sheet) makes it print again.
    function needsResume(printer: var): bool {
        return printer.state === "stopped" || root.accepting[printer.name] === false;
    }

    function stateText(printer: var): string {
        if (printer.state !== "stopped" && root.accepting[printer.name] === false)
            return qsTr("Not Accepting Jobs");
        switch (printer.state) {
        case "printing":
            return qsTr("Printing");
        case "holding":
            return qsTr("Holding New Jobs");
        case "stopped":
            return qsTr("Stopped");
        }
        return qsTr("Idle");
    }

    function statusOf(printer: var): string {
        return printer.name === root.defaultName ? qsTr("%1, Default").arg(root.stateText(printer)) : root.stateText(printer);
    }

    function dotOf(printer: var): color {
        return printer.state === "stopped" ? Appearance.colors.statusOff : printer.state === "holding" || root.accepting[printer.name] === false
            ? Appearance.colors.statusWarn : Appearance.colors.statusOn;
    }

    function kindText(printer: var): string {
        switch (Printers.kindOf(root.devices[printer.name])) {
        case "driverless":
            return qsTr("Driverless (IPP Everywhere)");
        case "usb":
            return qsTr("USB");
        case "network":
            return qsTr("Network");
        }
        return qsTr("Other");
    }

    function paperName(keyword: string): string {
        switch (keyword) {
        case "Letter":
            return qsTr("US Letter");
        case "Legal":
            return qsTr("US Legal");
        case "Tabloid":
            return qsTr("Tabloid");
        case "Executive":
            return qsTr("Executive");
        case "B5":
            return qsTr("JIS B5");
        }
        return keyword;
    }

    // What a printer's sheet shows.
    function details(printer: var): var {
        return {name: printer.name, title: root.displayName(printer), status: root.stateText(printer), message: printer.message,
            location: printer.location, kind: root.kindText(printer), isDefault: printer.name === root.defaultName, needsResume: root.needsResume(printer)};
    }

    function refresh(): void {
        root.system.query(Printers.QUERY.printers, "printers.list");
        root.system.query(Printers.QUERY.defaultPrinter, "printers.default");
        root.system.query(Printers.QUERY.devices, "printers.devices");
        root.system.query(Printers.QUERY.accepting, "printers.accepting");
    }

    function readPapers(): void {
        for (const p of root.printers) {
            if (root.papers[p.name] === undefined) {
                const argv = Printers.paperQuery(p.name);
                if (argv !== null)
                    root.system.query(argv, "printers.paper:" + p.name);
            }
        }
    }

    function chooseDefault(name: string): void {
        root.system.act("default printer", Printers.setDefault(name), "printers.act");
    }

    // The size for every queue that has it (macOS: one default for all printers).
    function choosePaper(keyword: string): void {
        for (const p of root.printers) {
            const own = root.papers[p.name];
            if (own !== undefined && own.choices.indexOf(keyword) >= 0)
                root.system.act("paper size", Printers.setPaper(p.name, keyword), "printers.act");
        }
    }

    // Add Printer…'s answer, and the confirmation of Remove Printer….
    function add(printer: var): void {
        root.system.act("add printer", Printers.addOp(printer), "printers.act");
    }

    function remove(name: string): void {
        root.system.act("remove printer", Printers.deleteOp(name), "printers.act");
    }

    function resume(name: string): void {
        root.system.act("resume printer", Printers.resumeOp(name), "printers.act");
    }

    function startSearching(): void {
        root.foundAnswered = false;
        root.found = [];
        root.searching = true;
        root.system.query(Printers.QUERY.found, "printers.found");
    }

    function stopSearching(): void {
        root.searching = false;
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag.startsWith("printers.paper:")) {
                const p = Object.assign({}, root.papers);
                p[tag.slice("printers.paper:".length)] = ok ? Printers.parsePaper(output) : {choices: [], current: ""};
                root.papers = p;
                return;
            }
            switch (tag) {
            case "printers.list":
                root.answered = true;
                root.available = ok;
                root.printers = ok ? Printers.parsePrinters(output) : [];
                root.readPapers();
                break;
            case "printers.default":
                root.defaultName = ok ? Printers.parseDefault(output) : "";
                break;
            case "printers.devices":
                root.devices = ok ? Printers.parseDevices(output) : {};
                break;
            case "printers.accepting":
                root.accepting = ok ? Printers.parseAccepting(output) : {};
                break;
            case "printers.found":
                if (root.searching) {
                    root.foundAnswered = true;
                    root.found = ok ? Printers.parseFound(output, root.printers) : [];
                }
                break;
            case "printers.act":
                root.papers = ({});
                root.refresh();
                break;
            }
        }
    }

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: true
        repeat: true
        onTriggered: {
            root.refresh();
            if (root.searching)
                root.system.query(Printers.QUERY.found, "printers.found");
        }
    }

    Component.onCompleted: root.refresh()

    SettingsGroup {
        visible: root.answered && !root.available
        footnote: qsTr("Printing is not available: CUPS did not answer.")
    }

    SettingsGroup {
        visible: root.available

        SettingsRow {
            title: qsTr("Default printer")

            ComboBox {
                inline: true
                enabled: root.printers.length > 0
                accessibleName: qsTr("Default printer")
                model: (root.defaultName === "" ? [{id: "", text: qsTr("None")}] : []).concat(root.printers.map(p => ({id: p.name, text: root.displayName(p)})))
                value: root.defaultName
                onPicked: id => {
                    if (id !== "")
                        root.chooseDefault(id);
                }
            }
        }

        SettingsRow {
            title: qsTr("Default paper size")

            ComboBox {
                inline: true
                enabled: root.paperChoices.length > 0
                accessibleName: qsTr("Default paper size")
                model: root.paperChoices.length > 0 ? root.paperChoices.map(k => ({id: k, text: root.paperName(k)})) : [{id: "", text: qsTr("None")}]
                value: root.paper.current
                onPicked: id => {
                    if (id !== "")
                        root.choosePaper(id);
                }
            }
        }
    }

    SettingsGroup {
        visible: root.available
        caption: qsTr("Printers")

        Repeater {
            model: root.printers

            delegate: PrinterRow {
                required property var modelData

                text: root.displayName(modelData)
                status: root.statusOf(modelData)
                dotColor: root.dotOf(modelData)
                onClicked: root.detailsRequested(root.details(modelData))
            }
        }

        SettingsRow {
            visible: root.printers.length === 0
            title: qsTr("No printers")
        }
    }

    // The push button under the list, right-aligned (macOS 27: Add Printer, Scanner, or Fax… and ?).
    Item {
        visible: root.available
        width: parent ? parent.width : implicitWidth
        height: Tokens.settingsPushRowGap - Tokens.settingsGroupGap + addButton.height

        Button {
            id: addButton
            push: true
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: qsTr("Add Printer…")
            onClicked: root.addRequested()
        }
    }

    ErrorNote {
        system: root.system
        tag: "printers.act"
    }

    DevNote {
        system: root.system
    }
}
