pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// grassfield-portal's print sheet (ADR-0035 D-7, step 6a; docs/specs/system-dialogs.md section 7, PR1-PR4): an application's
// Print… (xdg-desktop-portal's PreparePrint) on its window, as macOS's print panel lays out its settings: Printer (CUPS's
// printers, the default first, then Add Printer… which opens Settings > Printers), Copies, Pages (All Pages, the current page
// or the selection when the application has them, or a range typed "1-3, 5"), then Paper Size, Orientation and Scale, and
// Two-Sided and Colour when the printer has them; Save as PDF… at the bottom left, Cancel and Print at the bottom right. No
// preview: the document is not made yet (GTK renders it with the answer); step 6b brings the sheet with a preview for a Print
// with no sheet before it. Made by FilePanels.qml, modal over the application's window as its panels are.
// - Return prints when Print is enabled; Esc and the compositor's close cancel.
// - The printers are asked off the GUI thread (Print, apps/portal/src/print.h): "Looking for printers…" meanwhile; "No Printers
//   Available" with Add Printer… when there is none; a printer whose options have not come yet keeps the choices as they are.
// - A sheet that gets the keyboard late takes keys only after a click in it (the panels' rule, FilePanel.qml).
Window {
    id: sheet

    // Print (apps/portal/src/print.h).
    required property var host
    // FilePanels.qml.
    required property var manager
    required property int requestId
    // Print::toQml.
    required property var request

    // CUPS's printers ([{name, displayName, location, isDefault}]) and the one chosen; listing until the first answer.
    property var printers: []
    property string printer: ""
    property bool listing: true
    property bool listFailed: false
    // What the chosen printer supports (print::toQml(Capabilities)); `known` false until it says.
    property var capabilities: ({
            known: false,
            media: [],
            twoSided: false,
            color: false,
            maxCopies: 999
        })
    property bool reading: false
    // The sheet's choices (print::toQml(Choices)).
    property var choices: sheet.request.choices
    property bool answered: false
    // Save as PDF's Save panel is up: the sheet steps aside meanwhile.
    property bool saving: false
    property bool keysHeld: false
    property real shownAt: 0
    property real pressedAt: 0
    property bool everActive: false
    property bool testAnswered: false

    // ADR-0015: the sheet draws its own frame, as the panels do (gf-client-chrome-panel).
    property string gfChromeRole: "file-panel"

    // A label of the form, right-aligned against its control (its width set where it is used: the widest label's).
    component FormLabel: Text {
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    readonly property bool rangesValid: sheet.choices.pages !== "ranges" || sheet.host.tidyRanges(String(sheet.choices.ranges)) !== ""
    readonly property bool canPrint: !sheet.answered && sheet.printer !== "" && sheet.rangesValid
    readonly property string acceptText: sheet.request.acceptLabel ? String(sheet.request.acceptLabel) : qsTr("Print")

    title: sheet.request.title ? String(sheet.request.title) : qsTr("Print")
    color: Appearance.colors.windowBackground
    modality: sheet.request.modal && sheet.request.parented ? Qt.WindowModal : Qt.NonModal
    readonly property real contentHeight: form.implicitHeight + 2 * Tokens.panelSheetPadding + footer.height
    width: Tokens.filesPrintSheetWidth
    height: sheet.contentHeight
    minimumWidth: Tokens.filesPrintSheetWidth
    maximumWidth: Tokens.filesPrintSheetWidth
    minimumHeight: sheet.contentHeight
    maximumHeight: sheet.contentHeight

    function setChoice(key: string, value: var): void {
        const next = Object.assign({}, sheet.choices);
        next[key] = value;
        sheet.choices = next;
    }

    function choosePrinter(name: string): void {
        if (name === "__add") {
            sheet.host.addPrinter();
            return;
        }
        if (name === "" || name === sheet.printer)
            return;
        sheet.printer = name;
        sheet.reading = true;
        sheet.host.choosePrinter(sheet.requestId, name, Object.assign({}, sheet.choices, {
            printer: name
        }));
    }

    function pressPrint(): void {
        if (!sheet.canPrint || sheet.keysHeld)
            return;
        const given = Object.assign({}, sheet.choices, {
            printer: sheet.printer,
            outputUri: ""
        });
        if (given.pages === "ranges")
            given.ranges = sheet.host.tidyRanges(String(given.ranges));
        sheet.answered = sheet.host.answer(sheet.requestId, 0, given);
    }

    function cancel(): void {
        if (sheet.answered)
            return;
        sheet.answered = true;
        sheet.host.answer(sheet.requestId, 1, {});
    }

    function savePdf(): void {
        if (sheet.answered || sheet.saving || !sheet.request.canSavePdf || !sheet.rangesValid)
            return;
        sheet.saving = true;
        sheet.visible = false;
        const name = sheet.request.outputBasename ? String(sheet.request.outputBasename) : qsTr("Untitled");
        sheet.host.savePdf(sheet.requestId, name, qsTr("Save as PDF"));
    }

    Connections {
        target: sheet.host
        function onPrintersListed(id: int, printers: var, current: string, ok: bool): void {
            if (id !== sheet.requestId)
                return;
            sheet.printers = printers;
            sheet.listing = false;
            sheet.listFailed = !ok;
            if (current !== "" && current !== sheet.printer) {
                sheet.printer = current;
                sheet.reading = true;
            }
            if (current === "")
                sheet.printer = "";
        }
        function onPrinterChosen(id: int, printer: string, capabilities: var, choices: var): void {
            if (id !== sheet.requestId || printer !== sheet.printer)
                return;
            sheet.capabilities = capabilities;
            sheet.choices = choices;
            sheet.reading = false;
            sheet.testPrint();
        }
        function onPdfChosen(id: int, uri: string): void {
            if (id !== sheet.requestId || sheet.answered)
                return;
            sheet.saving = false;
            const given = Object.assign({}, sheet.choices, {
                printer: "",
                outputUri: uri
            });
            if (given.pages === "ranges")
                given.ranges = sheet.host.tidyRanges(String(given.ranges));
            sheet.answered = sheet.host.answer(sheet.requestId, 0, given);
            if (!sheet.answered)
                sheet.visible = true;
        }
        function onPdfCancelled(id: int): void {
            if (id !== sheet.requestId)
                return;
            // Cancel in the Save panel: back to the print sheet (macOS ends the print there; Grassfield keeps the choices made).
            sheet.saving = false;
            sheet.visible = true;
            sheet.requestActivate();
        }
    }

    // Dev plumbing (GRASSFIELD_PORTAL_TEST_ANSWER): "accept" prints on the chosen printer once its options are read, "cancel"
    // cancels once the sheet has drawn.
    function testPrint(): void {
        if (sheet.manager.testAnswer !== "accept" || sheet.testAnswered || !sheet.canPrint)
            return;
        sheet.testAnswered = true;
        Qt.callLater(sheet.pressPrint);
    }

    onFrameSwapped: {
        if (sheet.shownAt === 0)
            sheet.shownAt = Date.now();
        if (sheet.manager.testAnswer === "cancel" && !sheet.testAnswered) {
            sheet.testAnswered = true;
            Qt.callLater(sheet.cancel);
        }
    }

    onActiveChanged: {
        if (!sheet.active || sheet.everActive)
            return;
        sheet.everActive = true;
        // Late (shown a while ago, behind the lock or another window) and no click in it just now: keys wait for a click.
        const now = Date.now();
        const late = sheet.shownAt > 0 && now - sheet.shownAt > Tokens.filesPanelLateFocusMs;
        const clicked = sheet.pressedAt > 0 && now - sheet.pressedAt <= Tokens.filesPanelLateFocusMs;
        if (late && !clicked)
            sheet.keysHeld = true;
        else
            home.forceActiveFocus();
    }

    // Closed by the compositor (no answer yet): Cancel.
    onClosing: sheet.cancel()

    Item {
        id: home
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (sheet.keysHeld) {
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Escape) {
                sheet.cancel();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                sheet.pressPrint();
                event.accepted = true;
            }
        }

        Grid {
            id: form
            anchors.top: parent.top
            anchors.topMargin: Tokens.panelSheetPadding
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 2
            columnSpacing: Tokens.spacingSm
            rowSpacing: Tokens.spacingSm
            verticalItemAlignment: Grid.AlignVCenter
            enabled: !sheet.keysHeld

            readonly property real labelWidth: Math.max(printerLabel.implicitWidth, copiesLabel.implicitWidth, pagesLabel.implicitWidth,
                                                         paperLabel.implicitWidth, orientationLabel.implicitWidth, scaleLabel.implicitWidth,
                                                         sidesLabel.implicitWidth, colorLabel.implicitWidth)

            FormLabel {
                id: printerLabel
                width: form.labelWidth
                text: qsTr("Printer:")
            }
            ComboBox {
                id: printerBox
                width: Tokens.filesPrintFieldWidth
                accessibleName: qsTr("Printer")
                value: sheet.printer
                model: {
                    const items = [];
                    if (sheet.listing)
                        items.push({id: "", text: qsTr("Looking for printers…")});
                    else if (sheet.printers.length === 0)
                        items.push({id: "", text: sheet.listFailed ? qsTr("Printers Not Responding") : qsTr("No Printers Available")});
                    for (let i = 0; i < sheet.printers.length; i++)
                        items.push({id: String(sheet.printers[i].name), text: DisplayName.text(String(sheet.printers[i].displayName))});
                    items.push({id: "__add", text: qsTr("Add Printer…")});
                    return items;
                }
                onPicked: id => sheet.choosePrinter(id)
            }

            FormLabel {
                id: copiesLabel
                width: form.labelWidth
                text: qsTr("Copies:")
            }
            SpinBox {
                id: copiesBox
                accessibleName: qsTr("Copies")
                from: 1
                to: Math.max(1, Number(sheet.capabilities.maxCopies) || 1)
                enabled: sheet.printer !== ""
                onValueModified: sheet.setChoice("copies", copiesBox.value)
                // A Binding, not a plain one: a value the user stepped to would break that (the printer's limit comes later).
                Binding on value {
                    value: Number(sheet.choices.copies) || 1
                }
            }

            FormLabel {
                id: pagesLabel
                width: form.labelWidth
                text: qsTr("Pages:")
            }
            Row {
                spacing: Tokens.spacingSm
                ComboBox {
                    id: pagesBox
                    width: sheet.choices.pages === "ranges" ? Tokens.filesPrintFieldWidth / 2 : Tokens.filesPrintFieldWidth
                    accessibleName: qsTr("Pages")
                    value: String(sheet.choices.pages)
                    model: {
                        const items = [{id: "all", text: qsTr("All Pages")}];
                        if (sheet.request.hasCurrentPage)
                            items.push({id: "current", text: qsTr("Current Page")});
                        if (sheet.request.hasSelection)
                            items.push({id: "selection", text: qsTr("Selection")});
                        items.push({id: "ranges", text: qsTr("Range")});
                        return items;
                    }
                    onPicked: id => sheet.setChoice("pages", id)
                }
                TextField {
                    id: rangesField
                    visible: sheet.choices.pages === "ranges"
                    width: Tokens.filesPrintFieldWidth / 2 - Tokens.spacingSm
                    accessibleName: qsTr("Pages to print, for example 1-3, 5")
                    placeholderText: qsTr("1-3, 5")
                    text: String(sheet.choices.ranges)
                    onTextEdited: sheet.setChoice("ranges", rangesField.text)
                }
            }

            FormLabel {
                id: paperLabel
                width: form.labelWidth
                text: qsTr("Paper Size:")
            }
            ComboBox {
                width: Tokens.filesPrintFieldWidth
                accessibleName: qsTr("Paper Size")
                value: String(sheet.choices.media.name)
                model: {
                    const media = sheet.capabilities.known && sheet.capabilities.media.length > 0 ? sheet.capabilities.media : [sheet.choices.media];
                    return media.map(m => ({id: String(m.name), text: String(m.displayName)}));
                }
                onPicked: id => {
                    const media = sheet.capabilities.media || [];
                    for (let i = 0; i < media.length; i++) {
                        if (media[i].name === id)
                            sheet.setChoice("media", media[i]);
                    }
                }
            }

            FormLabel {
                id: orientationLabel
                width: form.labelWidth
                text: qsTr("Orientation:")
            }
            SegmentedControl {
                accessibleName: qsTr("Orientation")
                value: String(sheet.choices.orientation)
                model: [{id: "portrait", text: qsTr("Portrait")}, {id: "landscape", text: qsTr("Landscape")}]
                onPicked: id => sheet.setChoice("orientation", id)
            }

            FormLabel {
                id: scaleLabel
                width: form.labelWidth
                text: qsTr("Scale:")
            }
            Row {
                spacing: Tokens.spacingXs
                SpinBox {
                    id: scaleBox
                    accessibleName: qsTr("Scale, in per cent")
                    from: 1
                    to: 1000
                    onValueModified: sheet.setChoice("scale", scaleBox.value)
                    Binding on value {
                        value: Number(sheet.choices.scale) || 100
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: qsTr("%")
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }

            FormLabel {
                id: sidesLabel
                width: form.labelWidth
                visible: sheet.capabilities.twoSided === true
                text: qsTr("Two-Sided:")
            }
            ComboBox {
                visible: sheet.capabilities.twoSided === true
                width: Tokens.filesPrintFieldWidth
                accessibleName: qsTr("Two-Sided")
                value: String(sheet.choices.duplex)
                model: [{id: "simplex", text: qsTr("Off")}, {id: "horizontal", text: qsTr("Long-Edge Binding")}, {id: "vertical", text: qsTr("Short-Edge Binding")}]
                onPicked: id => sheet.setChoice("duplex", id)
            }

            FormLabel {
                id: colorLabel
                width: form.labelWidth
                visible: sheet.capabilities.color === true
                text: qsTr("Colour:")
            }
            ComboBox {
                visible: sheet.capabilities.color === true
                width: Tokens.filesPrintFieldWidth
                accessibleName: qsTr("Colour")
                value: sheet.choices.color ? "color" : "mono"
                model: [{id: "color", text: qsTr("Colour")}, {id: "mono", text: qsTr("Black & White")}]
                onPicked: id => sheet.setChoice("color", id === "color")
            }
        }

        Item {
            id: footer
            anchors.bottom: parent.bottom
            width: parent.width
            height: Tokens.panelSheetFooterHeight

            Rectangle {
                width: parent.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            Button {
                anchors.left: parent.left
                anchors.leftMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                visible: sheet.request.canSavePdf === true && !sheet.keysHeld
                enabled: !sheet.answered && sheet.rangesValid
                text: qsTr("Save as PDF…")
                onClicked: sheet.savePdf()
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                visible: sheet.keysHeld
                textFormat: Text.PlainText
                text: qsTr("Click the panel to use the keyboard in it.")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                spacing: Tokens.spacingSm

                Button {
                    text: qsTr("Cancel")
                    onClicked: sheet.cancel()
                }

                Button {
                    text: sheet.acceptText
                    primary: true
                    enabled: sheet.canPrint && !sheet.reading
                    onClicked: sheet.pressPrint()
                }
            }
        }
    }

    // The keys wait for a click (keysHeld): the first press anywhere ends the hold and goes on to what is under it. Every press
    // is noted on its way (pressedAt).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => {
            sheet.pressedAt = Date.now();
            if (sheet.keysHeld) {
                sheet.keysHeld = false;
                home.forceActiveFocus();
            }
            mouse.accepted = false;
        }
    }
}
