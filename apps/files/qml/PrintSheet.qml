pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// grassfield-portal's print sheet (ADR-0035 D-7, steps 6a and 6b; docs/specs/system-dialogs.md section 7, PR1-PR4): an
// application's Print… (xdg-desktop-portal's PreparePrint) on its window, as macOS's print panel lays out its settings: Printer
// (CUPS's printers, the default first, then Add Printer… which opens Settings > Printers), Presets (Default Settings, and Last
// Used Settings once something was printed), Copies, Pages (All Pages, the current page or the selection when the application
// has them, or a range typed "1-3, 5"), then Paper Size, Orientation and Scale, Two-Sided and Colour when the printer has them,
// and the printer's own options in disclosure sections (Media & Quality, Printer Options) when it reports any; the "PDF"
// pull-down (Save as PDF…, Open in Preview) at the bottom left, Cancel and Print at the bottom right. No preview over
// PreparePrint: the document is not made yet (GTK renders it with the answer). A document the application sends first (Print
// with no token, `request.document`) gets its preview on the left, page by page, and no Orientation or Scale (the document is
// laid out already). Made by FilePanels.qml, modal over the application's window as its panels are.
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

    // A document sent first: its pages (-1 while it is read, 0 when they cannot be drawn), the one shown and its image.
    readonly property bool document: sheet.request.document === true
    property int pages: -1
    property int page: 0
    property string pageSource: ""
    // A page asked and not drawn yet.
    property bool pageDrawing: false
    // The printer's own options (print::toQml(Capabilities).options) and the disclosure sections that hold them, as macOS
    // groups them; the sections open ({id: true}).
    readonly property var optionList: sheet.capabilities.options ? sheet.capabilities.options : []
    readonly property var sectionList: [{id: "quality", title: qsTr("Media & Quality")}, {id: "printer", title: qsTr("Printer Options")}].filter(
        section => sheet.optionList.some(o => o.section === section.id))
    property var openSections: ({})

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
    // A document sent first is printed, saved or opened once it is kept, whatever its preview does (documentRead).
    property bool documentKept: false
    readonly property bool documentRead: !sheet.document || sheet.documentKept
    // The user chose a paper: the document's own (documentPaper) no longer replaces it.
    property bool paperPicked: false
    // Not while the printer's options are read: Return would print with none of them (review of step 6a, MINOR 4).
    readonly property bool canPrint: !sheet.answered && sheet.printer !== "" && !sheet.reading && sheet.rangesValid && sheet.documentRead
    readonly property string acceptText: sheet.request.acceptLabel ? String(sheet.request.acceptLabel) : qsTr("Print")

    title: sheet.request.title ? String(sheet.request.title) : qsTr("Print")
    color: Appearance.colors.windowBackground
    modality: sheet.request.modal && sheet.request.parented ? Qt.WindowModal : Qt.NonModal
    readonly property real contentHeight: Math.max(formColumn.implicitHeight + 2 * Tokens.panelSheetPadding, preview.implicitHeight) + footer.height
    readonly property real contentWidth: Tokens.filesPrintSheetWidth + preview.width
    width: sheet.contentWidth
    height: sheet.contentHeight
    minimumWidth: sheet.contentWidth
    maximumWidth: sheet.contentWidth
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

    function setOption(name: string, value: string): void {
        const next = Object.assign({}, sheet.choices);
        next.options = Object.assign({}, sheet.choices.options || {});
        next.options[name] = value;
        sheet.choices = next;
    }

    // The Presets pop-up: Print applies it (the printer's options are needed) and answers with the choices (printerChosen).
    function choosePreset(preset: string): void {
        if (preset === String(sheet.choices.preset))
            return;
        sheet.setChoice("preset", preset);
        sheet.host.choosePreset(sheet.requestId, preset, sheet.choices);
    }

    function toggleSection(id: string): void {
        const next = Object.assign({}, sheet.openSections);
        next[id] = !next[id];
        sheet.openSections = next;
    }

    // The label of a printer's option, and its name for assistive technology.
    function optionLabel(name: string): string {
        switch (name) {
        case "media-source":
            return qsTr("Feed From:");
        case "media-type":
            return qsTr("Media Type:");
        case "print-quality":
            return qsTr("Quality:");
        case "output-bin":
            return qsTr("Output Bin:");
        case "finishings":
            return qsTr("Finishing:");
        }
        return name;
    }
    function optionTitle(name: string): string {
        switch (name) {
        case "media-source":
            return qsTr("Feed From");
        case "media-type":
            return qsTr("Media Type");
        case "print-quality":
            return qsTr("Quality");
        case "output-bin":
            return qsTr("Output Bin");
        case "finishings":
            return qsTr("Finishing");
        }
        return name;
    }
    // A value's name: the printer's (CUPS's), except the standard ones CUPS leaves as numbers (IPP's print-quality and
    // finishings enums), named here in the UI language by their keyword; another keyword keeps CUPS's name, or the keyword in
    // words (the security review of step 6b, NIT).
    function valueLabel(name: string, value: string, label: string, keyword: string): string {
        if (name === "print-quality") {
            if (value === "3")
                return qsTr("Draft");
            if (value === "4")
                return qsTr("Normal");
            if (value === "5")
                return qsTr("Best");
        }
        if (name === "finishings") {
            switch (keyword) {
            case "none":
                return qsTr("None");
            case "staple":
                return qsTr("Staple");
            case "punch":
                return qsTr("Punch");
            case "fold":
                return qsTr("Fold");
            case "bind":
                return qsTr("Bind");
            case "saddle-stitch":
                return qsTr("Saddle Stitch");
            case "staple-top-left":
                return qsTr("Staple Top Left");
            case "staple-bottom-left":
                return qsTr("Staple Bottom Left");
            case "staple-top-right":
                return qsTr("Staple Top Right");
            case "staple-bottom-right":
                return qsTr("Staple Bottom Right");
            case "staple-dual-left":
                return qsTr("Two Staples Left");
            case "staple-dual-top":
                return qsTr("Two Staples Top");
            case "punch-dual-left":
                return qsTr("Two Holes Left");
            case "punch-dual-top":
                return qsTr("Two Holes Top");
            }
            if (value === "3")
                return qsTr("None");
        }
        return label;
    }

    // The preview of a document sent first: the page shown, drawn for the page area's pixels.
    function requestPage(): void {
        if (!sheet.document || sheet.pages <= 0)
            return;
        const ratio = Math.max(1, Screen.devicePixelRatio);
        sheet.host.renderPage(sheet.requestId, sheet.page, Math.round(pageArea.width * ratio), Math.round(pageArea.height * ratio));
    }

    function turnPage(step: int): void {
        const next = Math.max(0, Math.min(sheet.pages - 1, sheet.page + step));
        if (next === sheet.page)
            return;
        sheet.page = next;
        // The page before goes at once (never under the new number): "Preparing Preview…" until this one is drawn.
        sheet.pageSource = "";
        sheet.pageDrawing = true;
        sheet.requestPage();
    }

    function pressPrint(): void {
        if (!sheet.canPrint || sheet.keysHeld)
            return;
        const given = Object.assign({}, sheet.choices, {
            printer: sheet.printer,
            outputUri: "",
            preview: false
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

    // Open in Preview: the document goes to Grassfield's Preview (a private copy), not to a printer.
    function openInPreview(): void {
        if (sheet.answered || sheet.saving || !sheet.request.canSavePdf || !sheet.rangesValid || !sheet.documentRead)
            return;
        const given = Object.assign({}, sheet.choices, {
            printer: "",
            outputUri: "",
            preview: true
        });
        if (given.pages === "ranges")
            given.ranges = sheet.host.tidyRanges(String(given.ranges));
        sheet.answered = sheet.host.answer(sheet.requestId, 0, given);
    }

    function savePdf(): void {
        if (sheet.answered || sheet.saving || !sheet.request.canSavePdf || !sheet.rangesValid || !sheet.documentRead)
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
                outputUri: uri,
                preview: false
            });
            if (given.pages === "ranges")
                given.ranges = sheet.host.tidyRanges(String(given.ranges));
            sheet.answered = sheet.host.answer(sheet.requestId, 0, given);
            if (!sheet.answered)
                sheet.host.reshow(sheet.requestId);
        }
        function onDocumentRead(id: int): void {
            if (id === sheet.requestId)
                sheet.documentKept = true;
        }
        function onDocumentPaper(id: int, media: var): void {
            if (id === sheet.requestId && !sheet.paperPicked)
                sheet.setChoice("media", media);
        }
        function onDocumentReady(id: int, pages: int): void {
            if (id !== sheet.requestId)
                return;
            sheet.pages = pages;
            sheet.page = 0;
            sheet.pageDrawing = pages > 0;
            sheet.requestPage();
            sheet.testPrint();
        }
        function onPageRendered(id: int, page: int, source: string): void {
            if (id !== sheet.requestId || page !== sheet.page)
                return;
            sheet.pageSource = source;
            sheet.pageDrawing = false;
        }
        function onPdfCancelled(id: int): void {
            if (id !== sheet.requestId)
                return;
            // Cancel in the Save panel: back to the print sheet (macOS ends the print there; Grassfield keeps the choices made).
            sheet.saving = false;
            // Shown again under the application's id, as it first was (Print's reshow).
            sheet.host.reshow(sheet.requestId);
            sheet.requestActivate();
        }
    }

    // Dev plumbing (GRASSFIELD_PORTAL_TEST_ANSWER): "accept" prints on the chosen printer once its options are read, "cancel"
    // cancels once the sheet has drawn.
    function testPrint(): void {
        // A document sent first: once its pages are counted too (the integration test checks the backend's child did it).
        if (sheet.manager.testAnswer !== "accept" || sheet.testAnswered || !sheet.canPrint || (sheet.document && sheet.pages < 0))
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
            } else if (sheet.document && (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp)) {
                sheet.turnPage(event.key === Qt.Key_PageDown ? 1 : -1);
                event.accepted = true;
            }
        }

        // The document's preview, on the left (a document sent first only), with its page arrows under it.
        Item {
            id: preview
            visible: sheet.document
            width: sheet.document ? Tokens.filesPrintPreviewWidth : 0
            height: parent.height - footer.height
            implicitHeight: sheet.document ? 2 * Tokens.panelSheetPadding + pageArea.height + Tokens.spacingSm + pageNav.height : 0

            Item {
                id: pageArea
                anchors.top: parent.top
                anchors.topMargin: Tokens.panelSheetPadding
                anchors.horizontalCenter: parent.horizontalCenter
                width: Tokens.filesPrintPreviewWidth - 2 * Tokens.panelSheetPadding
                height: Tokens.filesPrintPreviewHeight

                Image {
                    id: pageImage
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    source: sheet.pageSource
                    cache: false
                    smooth: true
                    visible: sheet.pageSource !== ""
                    Accessible.role: Accessible.Graphic
                    Accessible.name: qsTr("Page %1 of %2").arg(sheet.page + 1).arg(sheet.pages)
                }

                // The sheet of paper's edge.
                Rectangle {
                    visible: pageImage.visible && pageImage.status === Image.Ready
                    anchors.centerIn: parent
                    width: pageImage.paintedWidth
                    height: pageImage.paintedHeight
                    color: "transparent"
                    border.width: Tokens.appsBorderWidth
                    border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }

                Text {
                    anchors.centerIn: parent
                    visible: !pageImage.visible
                    textFormat: Text.PlainText
                    text: sheet.pages < 0 || sheet.pageDrawing ? qsTr("Preparing Preview…") : qsTr("No Preview")
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }

            Row {
                id: pageNav
                anchors.top: pageArea.bottom
                anchors.topMargin: Tokens.spacingSm
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Tokens.spacingSm
                visible: sheet.pages > 0

                ToolButton {
                    accessibleName: qsTr("Previous Page")
                    enabled: sheet.page > 0
                    onClicked: sheet.turnPage(-1)
                    Icon {
                        name: "chevron-right"
                        // The forward chevron turned: the back arrow.
                        rotation: 180
                        size: Tokens.menuIconSize
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: qsTr("%1 of %2").arg(sheet.page + 1).arg(sheet.pages)
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
                ToolButton {
                    accessibleName: qsTr("Next Page")
                    enabled: sheet.page < sheet.pages - 1
                    onClicked: sheet.turnPage(1)
                    Icon {
                        name: "chevron-right"
                        size: Tokens.menuIconSize
                    }
                }
            }
        }

        Column {
            id: formColumn
            anchors.top: parent.top
            anchors.topMargin: Tokens.panelSheetPadding
            x: preview.width + (Tokens.filesPrintSheetWidth - formColumn.width) / 2
            spacing: Tokens.spacingMd

            Grid {
                id: form
                columns: 2
                columnSpacing: Tokens.spacingSm
                rowSpacing: Tokens.spacingSm
                verticalItemAlignment: Grid.AlignVCenter
                enabled: !sheet.keysHeld

                readonly property real labelWidth: Math.max(printerLabel.implicitWidth, presetsLabel.implicitWidth, copiesLabel.implicitWidth,
                                                             pagesLabel.implicitWidth, paperLabel.implicitWidth, orientationLabel.implicitWidth,
                                                             scaleLabel.implicitWidth, sidesLabel.implicitWidth, colorLabel.implicitWidth,
                                                             optionLabels.widest)

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
                    id: presetsLabel
                    width: form.labelWidth
                    text: qsTr("Presets:")
                }
                ComboBox {
                    width: Tokens.filesPrintFieldWidth
                    accessibleName: qsTr("Presets")
                    value: String(sheet.choices.preset || "default")
                    model: {
                        const items = [{id: "default", text: qsTr("Default Settings")}];
                        if (sheet.request.hasLastUsed === true)
                            items.push({id: "last", text: qsTr("Last Used Settings")});
                        return items;
                    }
                    onPicked: id => sheet.choosePreset(id)
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
                            if (media[i].name === id) {
                                sheet.paperPicked = true;
                                sheet.setChoice("media", media[i]);
                            }
                        }
                    }
                }

                FormLabel {
                    id: orientationLabel
                    width: form.labelWidth
                    visible: !sheet.document
                    text: qsTr("Orientation:")
                }
                SegmentedControl {
                    visible: !sheet.document
                    accessibleName: qsTr("Orientation")
                    value: String(sheet.choices.orientation)
                    model: [{id: "portrait", text: qsTr("Portrait")}, {id: "landscape", text: qsTr("Landscape")}]
                    onPicked: id => sheet.setChoice("orientation", id)
                }

                FormLabel {
                    id: scaleLabel
                    width: form.labelWidth
                    visible: !sheet.document
                    text: qsTr("Scale:")
                }
                Row {
                    visible: !sheet.document
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

            // The widest label of the printer's options, so that their pop-ups line up with the ones above.
            Item {
                id: optionLabels
                visible: false
                readonly property real widest: Math.max(feedLabel.implicitWidth, typeLabel.implicitWidth, qualityLabel.implicitWidth,
                                                        binLabel.implicitWidth, finishingLabel.implicitWidth)
                FormLabel {
                    id: feedLabel
                    text: sheet.optionLabel("media-source")
                }
                FormLabel {
                    id: typeLabel
                    text: sheet.optionLabel("media-type")
                }
                FormLabel {
                    id: qualityLabel
                    text: sheet.optionLabel("print-quality")
                }
                FormLabel {
                    id: binLabel
                    text: sheet.optionLabel("output-bin")
                }
                FormLabel {
                    id: finishingLabel
                    text: sheet.optionLabel("finishings")
                }
            }

            // The printer's own options, in macOS's disclosure sections (closed at first), only the ones it reports.
            Repeater {
                model: sheet.sectionList

                delegate: Column {
                    id: section

                    required property var modelData
                    readonly property bool open: sheet.openSections[section.modelData.id] === true

                    width: form.width
                    spacing: Tokens.spacingSm
                    enabled: !sheet.keysHeld

                    Item {
                        id: header
                        width: section.width
                        height: Tokens.menuItemHeight
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: section.modelData.title
                        Accessible.checkable: true
                        Accessible.checked: section.open
                        Accessible.onPressAction: sheet.toggleSection(section.modelData.id)
                        // Space opens or closes it (Return stays the sheet's default button, as on macOS).
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Space) {
                                sheet.toggleSection(section.modelData.id);
                                event.accepted = true;
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: Tokens.appsBorderWidth
                            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                        }
                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: section.modelData.title
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.weight: Tokens.typographyMenuBoldWeight
                        }
                        Icon {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            name: section.open ? "chevron-down" : "chevron-right"
                            size: Tokens.menuIconSize
                        }
                        FocusRing {
                            visible: header.activeFocus
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: sheet.toggleSection(section.modelData.id)
                        }
                    }

                    Repeater {
                        model: section.open ? sheet.optionList.filter(o => o.section === section.modelData.id) : []

                        delegate: Row {
                            id: optionRow

                            required property var modelData

                            spacing: Tokens.spacingSm

                            FormLabel {
                                anchors.verticalCenter: parent.verticalCenter
                                width: form.labelWidth
                                text: sheet.optionLabel(String(optionRow.modelData.name))
                            }
                            ComboBox {
                                width: Tokens.filesPrintFieldWidth
                                accessibleName: sheet.optionTitle(String(optionRow.modelData.name))
                                value: {
                                    const chosen = (sheet.choices.options || {})[optionRow.modelData.name];
                                    return String(chosen !== undefined ? chosen : optionRow.modelData.defaultValue);
                                }
                                model: optionRow.modelData.values.map(v => ({
                                            id: String(v.value),
                                            text: sheet.valueLabel(String(optionRow.modelData.name), String(v.value), String(v.label),
                                                                   String(v.keyword || ""))
                                        }))
                                onPicked: id => sheet.setOption(String(optionRow.modelData.name), id)
                            }
                        }
                    }
                }
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

            // macOS's "PDF" pull-down: its label, always, and what to do with the document instead of printing it.
            ComboBox {
                id: pdfMenu
                anchors.left: parent.left
                anchors.leftMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.filesPrintPdfMenuWidth
                visible: sheet.request.canSavePdf === true && !sheet.keysHeld
                enabled: !sheet.answered && sheet.rangesValid && sheet.documentRead
                accessibleName: qsTr("PDF")
                value: ""
                displayText: qsTr("PDF")
                model: [{id: "save", text: qsTr("Save as PDF…")}, {id: "preview", text: qsTr("Open in Preview")}]
                onPicked: id => {
                    if (id === "save")
                        sheet.savePdf();
                    else if (id === "preview")
                        sheet.openInPreview();
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                visible: sheet.keysHeld
                textFormat: Text.PlainText
                text: qsTr("Click the panel to use the keyboard in it.")
                color: Appearance.windowSecondary
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
                    enabled: sheet.canPrint
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
