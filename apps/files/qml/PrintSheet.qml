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
    id: sheetItem
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

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
    property var choices: sheetItem.request.choices
    property bool answered: false
    // Save as PDF's Save panel is up: the sheet steps aside meanwhile.
    property bool saving: false
    property bool keysHeld: false
    property real shownAt: 0
    property real pressedAt: 0
    property bool everActive: false
    property bool testAnswered: false

    // A document sent first: its pages (-1 while it is read, 0 when they cannot be drawn), the one shown and its image.
    readonly property bool document: sheetItem.request.document === true
    property int pages: -1
    property int page: 0
    property string pageSource: ""
    // A page asked and not drawn yet.
    property bool pageDrawing: false
    // The printer's own options (print::toQml(Capabilities).options) and the disclosure sections that hold them, as macOS
    // groups them; the sections open ({id: true}).
    readonly property var optionList: sheetItem.capabilities.options ? sheetItem.capabilities.options : []
    readonly property var sectionList: [{id: "quality", title: qsTr("Media & Quality")}, {id: "printer", title: qsTr("Printer Options")}].filter(
        section => sheetItem.optionList.some(o => o.section === section.id))
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

    readonly property bool rangesValid: sheetItem.choices.pages !== "ranges" || sheetItem.host.tidyRanges(String(sheetItem.choices.ranges)) !== ""
    // A document sent first is printed, saved or opened once it is kept, whatever its preview does (documentRead).
    property bool documentKept: false
    readonly property bool documentRead: !sheetItem.document || sheetItem.documentKept
    // The user chose a paper: the document's own (documentPaper) no longer replaces it.
    property bool paperPicked: false
    // Not while the printer's options are read: Return would print with none of them (review of step 6a, MINOR 4).
    readonly property bool canPrint: !sheetItem.answered && sheetItem.printer !== "" && !sheetItem.reading && sheetItem.rangesValid && sheetItem.documentRead
    readonly property string acceptText: sheetItem.request.acceptLabel ? String(sheetItem.request.acceptLabel) : qsTr("Print")

    title: sheetItem.request.title ? String(sheetItem.request.title) : qsTr("Print")
    color: Appearance.colors.windowBackground
    modality: sheetItem.request.modal && sheetItem.request.parented ? Qt.WindowModal : Qt.NonModal
    readonly property real contentHeight: Math.max(formColumn.implicitHeight + 2 * Tokens.panelSheetPadding, preview.implicitHeight) + footer.height
    readonly property real contentWidth: Tokens.filesPrintSheetWidth + preview.width
    width: sheetItem.contentWidth
    height: sheetItem.contentHeight
    minimumWidth: sheetItem.contentWidth
    maximumWidth: sheetItem.contentWidth
    minimumHeight: sheetItem.contentHeight
    maximumHeight: sheetItem.contentHeight

    function setChoice(key: string, value: var): void {
        const next = Object.assign({}, sheetItem.choices);
        next[key] = value;
        sheetItem.choices = next;
    }

    function choosePrinter(name: string): void {
        if (name === "__add") {
            sheetItem.host.addPrinter();
            return;
        }
        if (name === "" || name === sheetItem.printer)
            return;
        sheetItem.printer = name;
        sheetItem.reading = true;
        sheetItem.host.choosePrinter(sheetItem.requestId, name, Object.assign({}, sheetItem.choices, {
            printer: name
        }));
    }

    function setOption(name: string, value: string): void {
        const next = Object.assign({}, sheetItem.choices);
        next.options = Object.assign({}, sheetItem.choices.options || {});
        next.options[name] = value;
        sheetItem.choices = next;
    }

    // The Presets pop-up: Print applies it (the printer's options are needed) and answers with the choices (printerChosen).
    function choosePreset(preset: string): void {
        if (preset === String(sheetItem.choices.preset))
            return;
        sheetItem.setChoice("preset", preset);
        sheetItem.host.choosePreset(sheetItem.requestId, preset, sheetItem.choices);
    }

    function toggleSection(id: string): void {
        const next = Object.assign({}, sheetItem.openSections);
        next[id] = !next[id];
        sheetItem.openSections = next;
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
        if (!sheetItem.document || sheetItem.pages <= 0)
            return;
        const ratio = Math.max(1, Screen.devicePixelRatio);
        sheetItem.host.renderPage(sheetItem.requestId, sheetItem.page, Math.round(pageArea.width * ratio), Math.round(pageArea.height * ratio));
    }

    function turnPage(step: int): void {
        const next = Math.max(0, Math.min(sheetItem.pages - 1, sheetItem.page + step));
        if (next === sheetItem.page)
            return;
        sheetItem.page = next;
        // The page before goes at once (never under the new number): "Preparing Preview…" until this one is drawn.
        sheetItem.pageSource = "";
        sheetItem.pageDrawing = true;
        sheetItem.requestPage();
    }

    function pressPrint(): void {
        if (!sheetItem.canPrint || sheetItem.keysHeld)
            return;
        const given = Object.assign({}, sheetItem.choices, {
            printer: sheetItem.printer,
            outputUri: "",
            preview: false
        });
        if (given.pages === "ranges")
            given.ranges = sheetItem.host.tidyRanges(String(given.ranges));
        sheetItem.answered = sheetItem.host.answer(sheetItem.requestId, 0, given);
    }

    function cancel(): void {
        if (sheetItem.answered)
            return;
        sheetItem.answered = true;
        sheetItem.host.answer(sheetItem.requestId, 1, {});
    }

    // Open in Preview: the document goes to Grassfield's Preview (a private copy), not to a printer.
    function openInPreview(): void {
        if (sheetItem.answered || sheetItem.saving || !sheetItem.request.canSavePdf || !sheetItem.rangesValid || !sheetItem.documentRead)
            return;
        const given = Object.assign({}, sheetItem.choices, {
            printer: "",
            outputUri: "",
            preview: true
        });
        if (given.pages === "ranges")
            given.ranges = sheetItem.host.tidyRanges(String(given.ranges));
        sheetItem.answered = sheetItem.host.answer(sheetItem.requestId, 0, given);
    }

    function savePdf(): void {
        if (sheetItem.answered || sheetItem.saving || !sheetItem.request.canSavePdf || !sheetItem.rangesValid || !sheetItem.documentRead)
            return;
        sheetItem.saving = true;
        sheetItem.visible = false;
        const name = sheetItem.request.outputBasename ? String(sheetItem.request.outputBasename) : qsTr("Untitled");
        sheetItem.host.savePdf(sheetItem.requestId, name, qsTr("Save as PDF"));
    }

    Connections {
        target: sheetItem.host
        function onPrintersListed(id: int, printers: var, current: string, ok: bool): void {
            if (id !== sheetItem.requestId)
                return;
            sheetItem.printers = printers;
            sheetItem.listing = false;
            sheetItem.listFailed = !ok;
            if (current !== "" && current !== sheetItem.printer) {
                sheetItem.printer = current;
                sheetItem.reading = true;
            }
            if (current === "")
                sheetItem.printer = "";
        }
        function onPrinterChosen(id: int, printer: string, capabilities: var, choices: var): void {
            if (id !== sheetItem.requestId || printer !== sheetItem.printer)
                return;
            sheetItem.capabilities = capabilities;
            sheetItem.choices = choices;
            sheetItem.reading = false;
            sheetItem.testPrint();
        }
        function onPdfChosen(id: int, uri: string): void {
            if (id !== sheetItem.requestId || sheetItem.answered)
                return;
            sheetItem.saving = false;
            const given = Object.assign({}, sheetItem.choices, {
                printer: "",
                outputUri: uri,
                preview: false
            });
            if (given.pages === "ranges")
                given.ranges = sheetItem.host.tidyRanges(String(given.ranges));
            sheetItem.answered = sheetItem.host.answer(sheetItem.requestId, 0, given);
            if (!sheetItem.answered)
                sheetItem.host.reshow(sheetItem.requestId);
        }
        function onDocumentRead(id: int): void {
            if (id === sheetItem.requestId)
                sheetItem.documentKept = true;
        }
        function onDocumentPaper(id: int, media: var): void {
            if (id === sheetItem.requestId && !sheetItem.paperPicked)
                sheetItem.setChoice("media", media);
        }
        function onDocumentReady(id: int, pages: int): void {
            if (id !== sheetItem.requestId)
                return;
            sheetItem.pages = pages;
            sheetItem.page = 0;
            sheetItem.pageDrawing = pages > 0;
            sheetItem.requestPage();
            sheetItem.testPrint();
        }
        function onPageRendered(id: int, page: int, source: string): void {
            if (id !== sheetItem.requestId || page !== sheetItem.page)
                return;
            sheetItem.pageSource = source;
            sheetItem.pageDrawing = false;
        }
        function onPdfCancelled(id: int): void {
            if (id !== sheetItem.requestId)
                return;
            // Cancel in the Save panel: back to the print sheet (macOS ends the print there; Grassfield keeps the choices made).
            sheetItem.saving = false;
            // Shown again under the application's id, as it first was (Print's reshow).
            sheetItem.host.reshow(sheetItem.requestId);
            sheetItem.requestActivate();
        }
    }

    // Dev plumbing (GRASSFIELD_PORTAL_TEST_ANSWER): "accept" prints on the chosen printer once its options are read, "cancel"
    // cancels once the sheet has drawn.
    function testPrint(): void {
        // A document sent first: once its pages are counted too (the integration test checks the backend's child did it).
        if (sheetItem.manager.testAnswer !== "accept" || sheetItem.testAnswered || !sheetItem.canPrint || (sheetItem.document && sheetItem.pages < 0))
            return;
        sheetItem.testAnswered = true;
        Qt.callLater(sheetItem.pressPrint);
    }

    onFrameSwapped: {
        if (sheetItem.shownAt === 0)
            sheetItem.shownAt = Date.now();
        if (sheetItem.manager.testAnswer === "cancel" && !sheetItem.testAnswered) {
            sheetItem.testAnswered = true;
            Qt.callLater(sheetItem.cancel);
        }
    }

    onActiveChanged: {
        if (!sheetItem.active || sheetItem.everActive)
            return;
        sheetItem.everActive = true;
        // Late (shown a while ago, behind the lock or another window) and no click in it just now: keys wait for a click.
        const now = Date.now();
        const late = sheetItem.shownAt > 0 && now - sheetItem.shownAt > Tokens.filesPanelLateFocusMs;
        const clicked = sheetItem.pressedAt > 0 && now - sheetItem.pressedAt <= Tokens.filesPanelLateFocusMs;
        if (late && !clicked)
            sheetItem.keysHeld = true;
        else
            home.forceActiveFocus();
    }

    // Closed by the compositor (no answer yet): Cancel.
    onClosing: sheetItem.cancel()

    Item {
        id: home
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (sheetItem.keysHeld) {
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Escape) {
                sheetItem.cancel();
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                sheetItem.pressPrint();
                event.accepted = true;
            } else if (sheetItem.document && (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp)) {
                sheetItem.turnPage(event.key === Qt.Key_PageDown ? 1 : -1);
                event.accepted = true;
            }
        }

        // The document's preview, on the left (a document sent first only), with its page arrows under it.
        Item {
            id: preview
            visible: sheetItem.document
            width: sheetItem.document ? Tokens.filesPrintPreviewWidth : 0
            height: parent.height - footer.height
            implicitHeight: sheetItem.document ? 2 * Tokens.panelSheetPadding + pageArea.height + Tokens.spacingSm + pageNav.height : 0

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
                    source: sheetItem.pageSource
                    cache: false
                    smooth: true
                    visible: sheetItem.pageSource !== ""
                    Accessible.role: Accessible.Graphic
                    Accessible.name: qsTr("Page %1 of %2").arg(sheetItem.page + 1).arg(sheetItem.pages)
                }

                // The sheet of paper's edge.
                Rectangle {
                    visible: pageImage.visible && pageImage.status === Image.Ready
                    anchors.centerIn: parent
                    width: pageImage.paintedWidth
                    height: pageImage.paintedHeight
                    color: "transparent"
                    border.width: sheetItem.hairline
                    border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }

                Text {
                    anchors.centerIn: parent
                    visible: !pageImage.visible
                    textFormat: Text.PlainText
                    text: sheetItem.pages < 0 || sheetItem.pageDrawing ? qsTr("Preparing Preview…") : qsTr("No Preview")
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
                visible: sheetItem.pages > 0

                ToolButton {
                    accessibleName: qsTr("Previous Page")
                    enabled: sheetItem.page > 0
                    onClicked: sheetItem.turnPage(-1)
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
                    text: qsTr("%1 of %2").arg(sheetItem.page + 1).arg(sheetItem.pages)
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
                ToolButton {
                    accessibleName: qsTr("Next Page")
                    enabled: sheetItem.page < sheetItem.pages - 1
                    onClicked: sheetItem.turnPage(1)
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
                enabled: !sheetItem.keysHeld

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
                    value: sheetItem.printer
                    model: {
                        const items = [];
                        if (sheetItem.listing)
                            items.push({id: "", text: qsTr("Looking for printers…")});
                        else if (sheetItem.printers.length === 0)
                            items.push({id: "", text: sheetItem.listFailed ? qsTr("Printers Not Responding") : qsTr("No Printers Available")});
                        for (let i = 0; i < sheetItem.printers.length; i++)
                            items.push({id: String(sheetItem.printers[i].name), text: DisplayName.text(String(sheetItem.printers[i].displayName))});
                        items.push({id: "__add", text: qsTr("Add Printer…")});
                        return items;
                    }
                    onPicked: id => sheetItem.choosePrinter(id)
                }

                FormLabel {
                    id: presetsLabel
                    width: form.labelWidth
                    text: qsTr("Presets:")
                }
                ComboBox {
                    width: Tokens.filesPrintFieldWidth
                    accessibleName: qsTr("Presets")
                    value: String(sheetItem.choices.preset || "default")
                    model: {
                        const items = [{id: "default", text: qsTr("Default Settings")}];
                        if (sheetItem.request.hasLastUsed === true)
                            items.push({id: "last", text: qsTr("Last Used Settings")});
                        return items;
                    }
                    onPicked: id => sheetItem.choosePreset(id)
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
                    to: Math.max(1, Number(sheetItem.capabilities.maxCopies) || 1)
                    enabled: sheetItem.printer !== ""
                    onValueModified: sheetItem.setChoice("copies", copiesBox.value)
                    // A Binding, not a plain one: a value the user stepped to would break that (the printer's limit comes later).
                    Binding on value {
                        value: Number(sheetItem.choices.copies) || 1
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
                        width: sheetItem.choices.pages === "ranges" ? Tokens.filesPrintFieldWidth / 2 : Tokens.filesPrintFieldWidth
                        accessibleName: qsTr("Pages")
                        value: String(sheetItem.choices.pages)
                        model: {
                            const items = [{id: "all", text: qsTr("All Pages")}];
                            if (sheetItem.request.hasCurrentPage)
                                items.push({id: "current", text: qsTr("Current Page")});
                            if (sheetItem.request.hasSelection)
                                items.push({id: "selection", text: qsTr("Selection")});
                            items.push({id: "ranges", text: qsTr("Range")});
                            return items;
                        }
                        onPicked: id => sheetItem.setChoice("pages", id)
                    }
                    TextField {
                        id: rangesField
                        visible: sheetItem.choices.pages === "ranges"
                        width: Tokens.filesPrintFieldWidth / 2 - Tokens.spacingSm
                        accessibleName: qsTr("Pages to print, for example 1-3, 5")
                        placeholderText: qsTr("1-3, 5")
                        text: String(sheetItem.choices.ranges)
                        onTextEdited: sheetItem.setChoice("ranges", rangesField.text)
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
                    value: String(sheetItem.choices.media.name)
                    model: {
                        const media = sheetItem.capabilities.known && sheetItem.capabilities.media.length > 0 ? sheetItem.capabilities.media : [sheetItem.choices.media];
                        return media.map(m => ({id: String(m.name), text: String(m.displayName)}));
                    }
                    onPicked: id => {
                        const media = sheetItem.capabilities.media || [];
                        for (let i = 0; i < media.length; i++) {
                            if (media[i].name === id) {
                                sheetItem.paperPicked = true;
                                sheetItem.setChoice("media", media[i]);
                            }
                        }
                    }
                }

                FormLabel {
                    id: orientationLabel
                    width: form.labelWidth
                    visible: !sheetItem.document
                    text: qsTr("Orientation:")
                }
                SegmentedControl {
                    visible: !sheetItem.document
                    accessibleName: qsTr("Orientation")
                    value: String(sheetItem.choices.orientation)
                    model: [{id: "portrait", text: qsTr("Portrait")}, {id: "landscape", text: qsTr("Landscape")}]
                    onPicked: id => sheetItem.setChoice("orientation", id)
                }

                FormLabel {
                    id: scaleLabel
                    width: form.labelWidth
                    visible: !sheetItem.document
                    text: qsTr("Scale:")
                }
                Row {
                    visible: !sheetItem.document
                    spacing: Tokens.spacingXs
                    SpinBox {
                        id: scaleBox
                        accessibleName: qsTr("Scale, in per cent")
                        from: 1
                        to: 1000
                        onValueModified: sheetItem.setChoice("scale", scaleBox.value)
                        Binding on value {
                            value: Number(sheetItem.choices.scale) || 100
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
                    visible: sheetItem.capabilities.twoSided === true
                    text: qsTr("Two-Sided:")
                }
                ComboBox {
                    visible: sheetItem.capabilities.twoSided === true
                    width: Tokens.filesPrintFieldWidth
                    accessibleName: qsTr("Two-Sided")
                    value: String(sheetItem.choices.duplex)
                    model: [{id: "simplex", text: qsTr("Off")}, {id: "horizontal", text: qsTr("Long-Edge Binding")}, {id: "vertical", text: qsTr("Short-Edge Binding")}]
                    onPicked: id => sheetItem.setChoice("duplex", id)
                }

                FormLabel {
                    id: colorLabel
                    width: form.labelWidth
                    visible: sheetItem.capabilities.color === true
                    text: qsTr("Colour:")
                }
                ComboBox {
                    visible: sheetItem.capabilities.color === true
                    width: Tokens.filesPrintFieldWidth
                    accessibleName: qsTr("Colour")
                    value: sheetItem.choices.color ? "color" : "mono"
                    model: [{id: "color", text: qsTr("Colour")}, {id: "mono", text: qsTr("Black & White")}]
                    onPicked: id => sheetItem.setChoice("color", id === "color")
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
                    text: sheetItem.optionLabel("media-source")
                }
                FormLabel {
                    id: typeLabel
                    text: sheetItem.optionLabel("media-type")
                }
                FormLabel {
                    id: qualityLabel
                    text: sheetItem.optionLabel("print-quality")
                }
                FormLabel {
                    id: binLabel
                    text: sheetItem.optionLabel("output-bin")
                }
                FormLabel {
                    id: finishingLabel
                    text: sheetItem.optionLabel("finishings")
                }
            }

            // The printer's own options, in macOS's disclosure sections (closed at first), only the ones it reports.
            Repeater {
                model: sheetItem.sectionList

                delegate: Column {
                    id: section

                    required property var modelData
                    readonly property bool open: sheetItem.openSections[section.modelData.id] === true

                    width: form.width
                    spacing: Tokens.spacingSm
                    enabled: !sheetItem.keysHeld

                    Item {
                        id: header
                        width: section.width
                        height: Tokens.menuItemHeight
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: section.modelData.title
                        Accessible.checkable: true
                        Accessible.checked: section.open
                        Accessible.onPressAction: sheetItem.toggleSection(section.modelData.id)
                        // Space opens or closes it (Return stays the sheet's default button, as on macOS).
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Space) {
                                sheetItem.toggleSection(section.modelData.id);
                                event.accepted = true;
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: sheetItem.hairline
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
                            onClicked: sheetItem.toggleSection(section.modelData.id)
                        }
                    }

                    Repeater {
                        model: section.open ? sheetItem.optionList.filter(o => o.section === section.modelData.id) : []

                        delegate: Row {
                            id: optionRow

                            required property var modelData

                            spacing: Tokens.spacingSm

                            FormLabel {
                                anchors.verticalCenter: parent.verticalCenter
                                width: form.labelWidth
                                text: sheetItem.optionLabel(String(optionRow.modelData.name)) // raw-name-ok: a print option keyword, never a file name
                            }
                            ComboBox {
                                width: Tokens.filesPrintFieldWidth
                                accessibleName: sheetItem.optionTitle(String(optionRow.modelData.name))
                                value: {
                                    const chosen = (sheetItem.choices.options || {})[optionRow.modelData.name];
                                    return String(chosen !== undefined ? chosen : optionRow.modelData.defaultValue);
                                }
                                model: optionRow.modelData.values.map(v => ({
                                            id: String(v.value),
                                            text: sheetItem.valueLabel(String(optionRow.modelData.name), String(v.value), String(v.label), // raw-name-ok: same
                                                                   String(v.keyword || ""))
                                        }))
                                onPicked: id => sheetItem.setOption(String(optionRow.modelData.name), id)
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
                height: sheetItem.hairline
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            // macOS's "PDF" pull-down: its label, always, and what to do with the document instead of printing it.
            ComboBox {
                id: pdfMenu
                anchors.left: parent.left
                anchors.leftMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.filesPrintPdfMenuWidth
                visible: sheetItem.request.canSavePdf === true && !sheetItem.keysHeld
                enabled: !sheetItem.answered && sheetItem.rangesValid && sheetItem.documentRead
                accessibleName: qsTr("PDF")
                value: ""
                displayText: qsTr("PDF")
                model: [{id: "save", text: qsTr("Save as PDF…")}, {id: "preview", text: qsTr("Open in Preview")}]
                onPicked: id => {
                    if (id === "save")
                        sheetItem.savePdf();
                    else if (id === "preview")
                        sheetItem.openInPreview();
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                visible: sheetItem.keysHeld
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
                    onClicked: sheetItem.cancel()
                }

                Button {
                    text: sheetItem.acceptText
                    primary: true
                    enabled: sheetItem.canPrint
                    onClicked: sheetItem.pressPrint()
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
            sheetItem.pressedAt = Date.now();
            if (sheetItem.keysHeld) {
                sheetItem.keysHeld = false;
                home.forceActiveFocus();
            }
            mouse.accepted = false;
        }
    }
}
