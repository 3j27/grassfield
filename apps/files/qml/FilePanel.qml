pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "PanelLogic.js" as PanelLogic

// An Open or Save panel of grassfield-portal (ADR-0035 D-4; docs/specs/system-dialogs.md section 1, FC1-FC6): the Files
// browser (sidebar, the four views, Back and Forward, the path pop-up, search, Glance) in a window that is the modal child of
// the application's window (FileChooser::present: xdg-foreign v2 and xdg-dialog v1, Hyprland dims and blocks the parent).
// - Open: files (or folders, `directory`); items the application cannot take are dimmed; the default button chooses the
//   selection, opens a selected folder in a file panel, or chooses the shown folder in a folder panel.
// - Save: compact (Save As and Where) or expanded to the browser by the disclosure button, as the application's panel was
//   left; the Format pop-up changes the name's extension; an existing name asks before replacing it.
// - SaveFiles: a folder for several files; the names that exist there are asked about together.
// Options: the Format pop-up (several filters) and the application's choices (pop-ups and check boxes). Only items on this
// computer are answered (the interface allows file:// only); a network location is refused with a message.
Window {
    id: panel

    required property var app
    // FileChooser (apps/portal/src/filechooser.h).
    required property var host
    // FilePanels.qml.
    required property var manager
    required property int requestId
    // chooser::toQml.
    required property var request
    // What this application's panel was left with: {folder, view, expanded} (FileChooser.memory).
    property var memory: ({})
    // {home, desktop, documents, downloads} (FileChooser.places).
    property var places: ({})

    readonly property string kind: String(panel.request.kind)
    readonly property bool saving: panel.kind === "save"
    readonly property bool foldersOnly: PanelLogic.choosesFolders(panel.request)
    // The compact Save panel (Save As and Where) or the whole browser.
    property bool expanded: !panel.saving || panel.memory.expanded === true
    property int filterIndex: panel.request.currentFilter
    // FolderModel.chooser of the listings (the tab reads it).
    readonly property var filter: PanelLogic.filterFor(panel.request, panel.filterIndex)
    // New Folder where a folder is the answer, or the place of a new file.
    readonly property bool canMakeFolder: panel.kind !== "open" || panel.request.directory === true
    // The view of this application's panels (the tab reads it when it opens).
    readonly property string viewMode: panel.memory.view ? String(panel.memory.view) : ""
    // The choices' values by id.
    property var choiceValues: {
        const values = {};
        const choices = panel.request.choices || [];
        for (let i = 0; i < choices.length; i++)
            values[choices[i].id] = choices[i].initial;
        return values;
    }
    readonly property string appName: panel.host.appName(panel.request.appId)
    readonly property string acceptText: panel.request.acceptLabel !== "" ? panel.request.acceptLabel : panel.kind === "open" ? qsTr("Open") : qsTr("Save")
    readonly property bool acceptEnabled: {
        if (panel.answered)
            return false;
        if (panel.saving)
            return nameField.text !== "";
        if (panel.kind === "saveFiles")
            return true;
        return PanelLogic.openEnabled(panel.request, tab.activeFolder ? tab.activeFolder.selectedCount : 0);
    }
    // Answered: the panel waits for the portal to take it away.
    property bool answered: false
    // A panel that first gets the keyboard late (it opened behind the lock, or under another window) takes keys only after a
    // click in it (spec common rule 6, the hold rule): a key meant for something else never answers it unseen.
    property bool keysHeld: false
    property real shownAt: 0
    property bool everActive: false
    property bool testAnswered: false
    readonly property bool sheetShown: goSheet.shown || newFolderSheet.shown || alertSheet.shown || kioSheets.sheetShown
    // The panel's own keys: not under a sheet or a menu, not while held.
    readonly property bool keysLive: !panel.keysHeld && !panel.sheetShown && !menus.visible

    // What BrowserTab and the sidebar read of their window.
    readonly property alias menuLayer: menus
    readonly property real previewExtension: 0
    // ADR-0015: the panel draws its own frame (a sheet's: no lights); the compositor plugin draws no titlebar on it
    // (config/hypr/grassfield/windows.lua, gf-client-chrome-panel).
    property string gfChromeRole: "file-panel"

    title: panel.request.title !== "" ? panel.request.title : panel.kind === "open" ? qsTr("Open") : qsTr("Save")
    color: Appearance.colors.windowBackground
    // Modal to the application's window when the application asked for it and gave one (xdg-dialog's modal; with no
    // parent Qt would block nothing anyway).
    modality: panel.request.modal && panel.request.parented ? Qt.WindowModal : Qt.NonModal
    width: panel.expanded ? Tokens.filesPanelWidth : Tokens.filesPanelCompactWidth
    height: panel.expanded ? Tokens.filesPanelHeight : panel.compactHeight
    minimumWidth: panel.expanded ? Tokens.filesPanelMinWidth : Tokens.filesPanelCompactWidth
    minimumHeight: panel.expanded ? Tokens.filesPanelMinHeight : panel.compactHeight
    readonly property real compactHeight: titleLine.height + saveHeader.height + options.height + footer.height

    // Answers ---------------------------------------------------------------------------------------------------------------

    function remember(): void {
        panel.host.remember(panel.request.appId, {
            folder: PanelLogic.isLocal(tab.url) ? String(tab.url) : (panel.memory.folder || ""),
            view: tab.viewMode,
            expanded: panel.saving ? panel.expanded : panel.memory.expanded === true
        });
    }

    function finish(uris: var): void {
        if (panel.answered)
            return;
        panel.answered = true;
        panel.remember();
        panel.host.answer(panel.requestId, 0, {
            uris: uris,
            choices: PanelLogic.choicesAnswer(panel.request, panel.choiceValues),
            filter: panel.filterIndex
        });
    }

    function cancel(): void {
        if (panel.answered)
            return;
        panel.answered = true;
        panel.remember();
        panel.host.answer(panel.requestId, 1, {});
    }

    // The default button (and Return, and a double-click on a file).
    function accept(): void {
        if (!panel.acceptEnabled)
            return;
        if (panel.saving)
            panel.save();
        else if (panel.kind === "saveFiles")
            panel.saveFiles();
        else
            panel.open();
    }

    function selection(): var {
        const m = tab.activeFolder;
        if (!m)
            return [];
        return m.selectedRows().map(r => ({url: m.urlAt(r), isDir: m.isDirAt(r)}));
    }

    function refuseRemote(): void {
        panel.alert(qsTr("This location can’t be used"),
                    panel.appName !== "" ? qsTr("“%1” can only use items on this computer. Choose an item in a folder on this computer.").arg(panel.appName)
                                         : qsTr("The application can only use items on this computer. Choose an item in a folder on this computer."));
    }

    function open(): void {
        const result = PanelLogic.openAction(panel.request, panel.selection(), tab.url);
        if (result.action === "enter") {
            tab.navigate(Qt.url(result.url), true);
        } else if (result.action === "choose") {
            if (!result.uris.every(u => PanelLogic.isLocal(u)))
                panel.refuseRemote();
            else
                panel.finish(result.uris);
        }
    }

    function save(): void {
        const name = nameField.text;
        if (!panel.app.isValidFileName(name)) {
            panel.alert(qsTr("The name “%1” can’t be used.").arg(DisplayName.text(name)),
                        qsTr("Names can’t be empty, “.” or “..”, contain “/”, or be longer than 255 bytes."));
            return;
        }
        if (!PanelLogic.isLocal(tab.url)) {
            panel.refuseRemote();
            return;
        }
        const target = PanelLogic.childUrl(tab.url, name);
        const kind = panel.host.pathKind(Qt.url(target));
        if (kind === 2) {
            panel.alert(qsTr("“%1” is a folder.").arg(DisplayName.text(name)), qsTr("Choose another name, or open the folder to save in it."));
        } else if (kind === 1) {
            // macOS: Cancel is the default; Replace overwrites (the application writes the file).
            panel.ask(qsTr("“%1” already exists. Do you want to replace it?").arg(DisplayName.text(name)),
                      qsTr("A file or folder with the same name already exists in the folder “%1”. Replacing it will overwrite its current contents.").arg(DisplayName.text(tab.title)),
                      qsTr("Replace"), () => panel.finish([target]));
        } else {
            panel.finish([target]);
        }
    }

    function saveFiles(): void {
        const chosen = panel.selection().filter(s => s.isDir);
        const folder = chosen.length > 0 ? String(chosen[0].url) : String(tab.url);
        if (!PanelLogic.isLocal(folder)) {
            panel.refuseRemote();
            return;
        }
        const names = panel.request.files || [];
        const uris = names.map(n => PanelLogic.childUrl(folder, n));
        const clashes = PanelLogic.clashes(names, folder, u => panel.host.pathKind(Qt.url(u)));
        const where = DisplayName.text(decodeURIComponent(folder.replace(/\/+$/, "").split("/").pop()) || "/");
        if (clashes.some(c => c.folder)) {
            panel.alert(qsTr("A folder in “%1” has the name of an item to save.").arg(where), clashes.filter(c => c.folder).map(c => DisplayName.text(c.name)).join("\n"));
        } else if (clashes.length > 0) {
            const shown = clashes.slice(0, 8).map(c => DisplayName.text(c.name));
            if (clashes.length > 8)
                shown.push(qsTr("and %1 more").arg(clashes.length - 8));
            panel.ask(clashes.length === 1 ? qsTr("“%1” already exists. Do you want to replace it?").arg(shown[0])
                                           : qsTr("%1 items already exist in “%2”. Do you want to replace them?").arg(clashes.length).arg(where),
                      (clashes.length > 1 ? shown.join("\n") + "\n\n" : "") + qsTr("Replacing them will overwrite their current contents."),
                      qsTr("Replace"), () => panel.finish(uris));
        } else {
            panel.finish(uris);
        }
    }

    // A message with OK only.
    function alert(title: string, message: string): void {
        alertSheet.title = title;
        alertSheet.message = message;
        alertSheet.confirmText = qsTr("OK");
        alertSheet.destructive = false;
        alertSheet.showCancel = false;
        alertSheet.returnCancels = false;
        alertSheet.confirmHandler = () => "";
        alertSheet.focusBack = panel.focusTarget();
        alertSheet.open();
    }

    // A destructive question: Cancel is the default (Return, Esc), `confirmText` does `action`.
    function ask(title: string, message: string, confirmText: string, action: var): void {
        alertSheet.title = title;
        alertSheet.message = message;
        alertSheet.confirmText = confirmText;
        alertSheet.destructive = true;
        alertSheet.showCancel = true;
        alertSheet.returnCancels = true;
        alertSheet.confirmHandler = () => {
            action();
            return "";
        };
        alertSheet.focusBack = panel.focusTarget();
        alertSheet.open();
    }

    // What has the keyboard when nothing else does: the Save As field, else the view.
    function focusTarget(): Item {
        return panel.saving ? nameField : tab.view;
    }

    function focusStart(): void {
        if (panel.saving) {
            nameField.forceActiveFocus();
            nameField.select(0, panel.app.baseNameLength(nameField.text, false));
        } else {
            tab.focusView();
        }
    }

    // What BrowserTab asks of its panel ------------------------------------------------------------------------------------

    // A double-click on a file: an Open panel chooses it (when it can take it), a Save panel takes its name and saves.
    function fileActivated(model: var, row: int): void {
        if (panel.saving) {
            nameField.text = model.nameAt(row);
            panel.accept();
        } else if (panel.kind === "open" && !panel.foldersOnly) {
            model.select(row, 0);
            if (model.isSelected(row))
                panel.accept();
        }
    }

    // A view chosen in the panel: kept for this application when the panel closes (tab.viewMode).
    function viewChosen(mode: string): void {
    }

    // Items dropped on the panel: the first is shown, selected, in its folder (macOS); nothing moves.
    function reveal(urls: var): void {
        if (!urls || urls.length === 0)
            return;
        tab.navigate(Qt.url(PanelLogic.parentUrl(urls[0])), true);
        tab.folder.expect(urls[0], false);
    }

    function goToFolder(text: string): void {
        goSheet.focusBack = panel.focusTarget();
        goSheet.setField(text);
        goSheet.open();
    }

    function newFolder(): void {
        if (!panel.canMakeFolder || !tab.activeFolder || !tab.activeFolder.writable)
            return;
        newFolderSheet.focusBack = panel.focusTarget();
        newFolderSheet.setField(qsTr("untitled folder"));
        newFolderSheet.open();
    }

    // For BrowserTab's code paths a panel never takes (tabs, Get Info, confirmations of file operations).
    function newTab(url: url, restore: var): void {
        tab.navigate(url, true);
    }

    function showInfo(info: var): void {
    }

    function confirm(title: string, message: string, confirmText: string, action: var): void {
    }

    function customizeFolders(urls: var, name: string, iconName: string): void {
    }

    function navigatePlace(key: string): void {
        const url = panel.places[key];
        if (url)
            tab.navigate(Qt.url(url), true);
    }

    // The window ------------------------------------------------------------------------------------------------------------

    onVisibleChanged: {
        if (panel.visible && panel.shownAt === 0)
            panel.shownAt = Date.now();
    }

    onActiveChanged: {
        if (!panel.active)
            return;
        panel.manager.lastActiveWindow = panel;
        if (!panel.everActive) {
            panel.everActive = true;
            if (Date.now() - panel.shownAt > Tokens.filesPanelLateFocusMs)
                panel.keysHeld = true;
            else
                panel.focusStart();
        }
    }

    // Closed by the compositor (no answer yet): a cancel.
    onClosing: panel.cancel()

    onFilterChanged: tab.applyChooser()

    onFrameSwapped: {
        if (panel.manager.testAnswer === "" || panel.testAnswered)
            return;
        panel.testAnswered = true;
        const answer = panel.manager.testAnswer;
        Qt.callLater(() => {
            if (answer === "accept")
                panel.accept();
            else
                panel.cancel();
        });
    }

    Component.onCompleted: {
        if (panel.saving)
            nameField.text = panel.request.currentName;
    }

    // Keys (Ctrl stands for Command, as in Files) ----------------------------------------------------------------------------

    Shortcut {
        sequences: ["Ctrl+Shift+G", "Ctrl+L"]
        enabled: panel.keysLive && panel.expanded
        onActivated: panel.goToFolder("")
    }
    Shortcut {
        sequences: ["Ctrl+[", "Alt+Left"]
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.back()
    }
    Shortcut {
        sequences: ["Ctrl+]", "Alt+Right"]
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.forward()
    }
    Shortcut {
        sequences: ["Ctrl+Up", "Alt+Up"]
        enabled: panel.keysLive
        onActivated: tab.up()
    }
    Shortcut {
        sequences: ["Ctrl+Down", "Alt+Down", "Ctrl+O"]
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.openSelection()
    }
    Shortcut {
        sequence: "Ctrl+Shift+H"
        enabled: panel.keysLive
        onActivated: panel.navigatePlace("home")
    }
    Shortcut {
        sequence: "Ctrl+Shift+D"
        enabled: panel.keysLive
        onActivated: panel.navigatePlace("desktop")
    }
    Shortcut {
        sequence: "Ctrl+Shift+O"
        enabled: panel.keysLive
        onActivated: panel.navigatePlace("documents")
    }
    Shortcut {
        sequence: "Ctrl+Alt+L"
        enabled: panel.keysLive
        onActivated: panel.navigatePlace("downloads")
    }
    Shortcut {
        sequence: "Ctrl+1"
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.setViewModeByNumber(1)
    }
    Shortcut {
        sequence: "Ctrl+2"
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.setViewModeByNumber(2)
    }
    Shortcut {
        sequence: "Ctrl+3"
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.setViewModeByNumber(3)
    }
    Shortcut {
        sequence: "Ctrl+4"
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.setViewModeByNumber(4)
    }
    Shortcut {
        // Show Hidden Files: Files' key, and the panels' own (Cmd-Shift-.).
        sequences: ["Ctrl+H", "Ctrl+Shift+.", "Ctrl+>"]
        enabled: panel.keysLive
        onActivated: panel.app.showHidden = !panel.app.showHidden
    }
    Shortcut {
        sequence: "Ctrl+F"
        enabled: panel.keysLive && panel.expanded
        onActivated: searchCapsule.focusField()
    }
    Shortcut {
        sequence: "Ctrl+A"
        enabled: panel.keysLive && panel.expanded && panel.kind === "open" && panel.request.multiple === true
        onActivated: tab.activeFolder.selectAll()
    }
    Shortcut {
        sequence: "Ctrl+Shift+N"
        enabled: panel.keysLive && panel.expanded && panel.canMakeFolder
        onActivated: panel.newFolder()
    }
    Shortcut {
        sequence: "Ctrl+Y"
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.glance()
    }
    Shortcut {
        sequence: "Ctrl+Shift+P"
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.togglePreview()
    }
    Shortcut {
        sequences: ["Ctrl+R", "F5"]
        enabled: panel.keysLive && panel.expanded
        onActivated: tab.folder.reload()
    }

    // Layout ----------------------------------------------------------------------------------------------------------------

    // Everything but the sheets and the menus: Esc and Cmd-. that no control took cancel the panel (the views answer Esc
    // themselves, the search field clears first; a pop-up or a sheet keeps its own).
    FocusScope {
        id: content
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape || (event.key === Qt.Key_Period && (event.modifiers & Qt.ControlModifier))) {
                panel.cancel();
                event.accepted = true;
            }
        }

        // The application's title, as NSSavePanel shows its message: one line above everything.
        Text {
            id: titleLine
            visible: panel.request.title !== ""
            width: parent.width
            height: visible ? implicitHeight + 2 * Tokens.spacingSm : 0
            topPadding: Tokens.spacingSm
            leftPadding: Tokens.spacingLg
            rightPadding: Tokens.spacingLg
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            elide: Text.ElideRight
            maximumLineCount: 1
            text: panel.request.title
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        // Save As (Save): the name, the disclosure button, and Where while compact.
        Item {
            id: saveHeader
            anchors.top: titleLine.bottom
            visible: panel.saving
            width: parent.width
            height: visible ? saveGrid.implicitHeight + 2 * Tokens.spacingMd : 0

            Grid {
                id: saveGrid
                anchors.centerIn: parent
                columns: 3
                columnSpacing: Tokens.spacingSm
                rowSpacing: Tokens.spacingSm
                verticalItemAlignment: Grid.AlignVCenter

                Text {
                    width: Tokens.filesPanelLabelWidth
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    text: qsTr("Save As:")
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                TextField {
                    id: nameField
                    width: Tokens.filesPanelFieldWidth
                    accessibleName: qsTr("Save As")
                    Keys.onReturnPressed: event => {
                        panel.accept();
                        event.accepted = true;
                    }
                    Keys.onEnterPressed: event => {
                        panel.accept();
                        event.accepted = true;
                    }
                }

                // The disclosure button: the compact panel or the browser (macOS: a chevron in a square).
                ToolButton {
                    iconName: "chevron-down"
                    iconRotation: panel.expanded ? 180 : 0
                    accessibleName: panel.expanded ? qsTr("Show Less") : qsTr("Show More")
                    onClicked: panel.expanded = !panel.expanded
                }

                Text {
                    visible: !panel.expanded
                    width: Tokens.filesPanelLabelWidth
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    text: qsTr("Where:")
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                // Where: the shown folder and the folders enclosing it, then the standard places.
                ComboBox {
                    id: whereBox
                    visible: !panel.expanded
                    width: Tokens.filesPanelFieldWidth
                    accessibleName: qsTr("Where")
                    value: String(tab.url)
                    model: {
                        const items = [];
                        const seen = {};
                        const segments = tab.segments;
                        const add = (url, label) => {
                            const key = String(url);
                            if (key === "" || seen[key])
                                return;
                            seen[key] = true;
                            items.push({id: key, text: DisplayName.text(label)});
                        };
                        add(tab.url, tab.title);
                        for (let i = segments.length - 2; i >= 0; i--)
                            add(segments[i].url, segments[i].label);
                        for (const key of ["desktop", "documents", "downloads", "home"]) {
                            const url = panel.places[key];
                            if (url)
                                add(url, decodeURIComponent(String(url).replace(/\/+$/, "").split("/").pop()));
                        }
                        return items;
                    }
                    onPicked: id => tab.navigate(Qt.url(id), true)
                }

                Item {
                    visible: !panel.expanded
                    width: 1
                    height: 1
                }
            }
        }

        // The browser: the sidebar, the toolbar and the listing.
        Item {
            id: browser
            anchors.top: saveHeader.bottom
            anchors.bottom: options.top
            width: parent.width
            visible: panel.expanded

            Rectangle {
                visible: panel.saving
                width: parent.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            Sidebar {
                id: sidebar
                width: Tokens.filesSidebarWidth
                height: parent.height
                app: panel.app
                tab: tab
            }

            Item {
                id: main
                x: sidebar.width
                width: parent.width - x
                height: parent.height

                UnifiedToolbar {
                    id: toolbar
                    z: 1
                    width: parent.width
                    window: panel
                    showControls: false
                    showTitle: false
                    doubleClickAction: "none"

                    leading: [
                        NavCapsule {
                            id: navCapsule
                            tab: tab
                        },
                        // The path pop-up: the shown folder; its menu lists the folders enclosing it (macOS panels).
                        Rectangle {
                            id: pathButton
                            width: Math.min(pathRow.implicitWidth + 2 * Tokens.spacingMd, Tokens.filesSearchWidth)
                            height: Tokens.filesToolbarCapsule
                            radius: height / 2
                            color: Appearance.buttonFill

                            ToolButton {
                                id: pathTool
                                anchors.fill: parent
                                capsule: true
                                buttonSize: Tokens.filesToolbarCapsule
                                accessibleName: qsTr("Location: %1").arg(DisplayName.text(tab.title))
                                onClicked: {
                                    const segments = tab.segments;
                                    const items = [];
                                    for (let i = segments.length - 1; i >= 0; i--)
                                        items.push({id: String(i), text: DisplayName.text(segments[i].label), iconName: "folder"});
                                    const p = pathTool.mapToItem(null, 0, pathTool.height + Tokens.spacingXs);
                                    if (items.length > 0)
                                        menus.open(items, p.x, p.y, id => tab.navigate(segments[parseInt(id)].url, true), tab.view, false);
                                }

                                Row {
                                    id: pathRow
                                    anchors.centerIn: parent
                                    spacing: Tokens.spacingXs

                                    Icon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "folder"
                                        size: Tokens.menuIconSize
                                        color: pathTool.foreground
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, Tokens.filesSearchWidth - 2 * Tokens.spacingMd - 2 * Tokens.menuIconSize)
                                        textFormat: Text.PlainText
                                        elide: Text.ElideMiddle
                                        text: DisplayName.text(tab.title)
                                        color: pathTool.foreground
                                        font.family: Appearance.fontFamily
                                        font.pixelSize: Tokens.typographyBodySize
                                        font.weight: Tokens.typographyMenuBoldWeight
                                    }

                                    Icon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "chevron-down"
                                        size: Tokens.filesViewPopupChevronSize
                                        color: pathTool.foreground
                                    }
                                }
                            }
                        }
                    ]

                    trailing: Row {
                        spacing: Tokens.spacingSm

                        ViewSwitcher {
                            id: viewSwitcher
                            anchors.verticalCenter: parent.verticalCenter
                            tab: tab
                            menuLayer: menus
                            compact: searchCapsule.expanded || navCapsule.width + pathButton.width + viewSwitcher.fullWidth + searchCapsule.width + 2 * Tokens.windowItemsGap + 2 * Tokens.windowItemsInset + Tokens.spacingSm > main.width
                        }

                        SearchCapsule {
                            id: searchCapsule
                            anchors.verticalCenter: parent.verticalCenter
                            tab: tab
                        }
                    }
                }

                Rectangle {
                    id: toolbarRule
                    anchors.top: toolbar.bottom
                    width: parent.width
                    height: Tokens.appsBorderWidth
                    opacity: tab.scrolled ? 1 : 0
                    color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }

                BrowserTab {
                    id: tab
                    anchors.top: toolbarRule.bottom
                    anchors.bottom: parent.bottom
                    width: parent.width
                    focus: panel.expanded && !panel.saving
                    app: panel.app
                    win: panel
                    chooser: panel
                    startUrl: Qt.url(PanelLogic.startFolder(panel.request, panel.memory, panel.places, u => panel.host.pathKind(Qt.url(u)) === 2))
                }
            }
        }

        // A file selected in the Save panel's browser gives its name (macOS).
        Connections {
            target: panel.saving ? tab.activeFolder : null
            function onSelectionChanged(): void {
                const m = tab.activeFolder;
                const rows = m ? m.selectedRows() : [];
                if (rows.length === 1 && !m.isDirAt(rows[0]))
                    nameField.text = m.nameAt(rows[0]);
            }
        }

        // Options: the Format pop-up and the application's choices.
        Item {
            id: options
            readonly property bool formats: (panel.request.filters || []).length > 1
            readonly property bool shown: options.formats || (panel.request.choices || []).length > 0
            anchors.bottom: footer.top
            width: parent.width
            visible: options.shown
            height: visible ? optionsFlow.implicitHeight + 2 * Tokens.spacingMd : 0

            Rectangle {
                width: parent.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            Flow {
                id: optionsFlow
                anchors.centerIn: parent
                width: Math.min(implicitWidth, parent.width - 2 * Tokens.spacingLg)
                spacing: Tokens.spacingLg

                Row {
                    visible: options.formats
                    spacing: Tokens.spacingSm

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: panel.kind === "open" ? qsTr("Show:") : qsTr("Format:")
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }

                    ComboBox {
                        accessibleName: panel.kind === "open" ? qsTr("Show") : qsTr("Format")
                        model: (panel.request.filters || []).map((f, i) => ({id: String(i), text: f.name}))
                        value: String(panel.filterIndex)
                        onPicked: id => {
                            const index = parseInt(id);
                            if (panel.saving)
                                nameField.text = PanelLogic.nameForFormat(nameField.text, panel.request.filters[index].globs);
                            panel.filterIndex = index;
                        }
                    }
                }

                Repeater {
                    model: panel.request.choices || []

                    Row {
                        id: choice
                        required property var modelData
                        spacing: Tokens.spacingSm

                        Text {
                            visible: choice.modelData.options.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: choice.modelData.label
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }

                        ComboBox {
                            visible: choice.modelData.options.length > 0
                            accessibleName: choice.modelData.label
                            model: choice.modelData.options.map(o => ({id: o.id, text: o.label}))
                            value: panel.choiceValues[choice.modelData.id] ?? ""
                            onPicked: id => {
                                const next = Object.assign({}, panel.choiceValues);
                                next[choice.modelData.id] = id;
                                panel.choiceValues = next;
                            }
                        }

                        CheckBox {
                            visible: choice.modelData.options.length === 0
                            text: choice.modelData.label
                            checked: panel.choiceValues[choice.modelData.id] === "true"
                            onToggled: {
                                const next = Object.assign({}, panel.choiceValues);
                                next[choice.modelData.id] = checked ? "true" : "false";
                                panel.choiceValues = next;
                            }
                        }
                    }
                }
            }
        }

        // The footer: New Folder at the leading edge; Cancel and the default button at the trailing edge.
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
                visible: panel.canMakeFolder && panel.expanded && !panel.keysHeld
                enabled: tab.activeFolder !== null && tab.activeFolder.writable
                text: qsTr("New Folder")
                onClicked: panel.newFolder()
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Tokens.panelSheetPadding
                anchors.verticalCenter: parent.verticalCenter
                visible: panel.keysHeld
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
                    onClicked: panel.cancel()
                }

                Button {
                    id: defaultButton
                    text: panel.acceptText
                    primary: true
                    enabled: panel.acceptEnabled
                    onClicked: panel.accept()
                }
            }
        }

    }

    // The keys wait for a click (keysHeld): this takes them meanwhile, and the first press anywhere in the panel ends the
    // hold and goes on to what is under it.
    Item {
        id: hold
        anchors.fill: parent
        z: 10
        visible: panel.keysHeld
        focus: panel.keysHeld
        Keys.onPressed: event => {
            event.accepted = true;
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => {
                panel.keysHeld = false;
                panel.focusStart();
                mouse.accepted = false;
            }
        }
    }

    // Sheets ----------------------------------------------------------------------------------------------------------------

    Sheet {
        id: goSheet
        title: qsTr("Go to the folder:")
        withField: true
        placeholder: qsTr("~/Documents, /usr/share or trash:/")
        confirmText: qsTr("Go")
        confirmHandler: text => {
            const url = panel.app.resolveLocation(text, tab.url);
            if (String(url) === "")
                return qsTr("The folder “%1” can’t be found.").arg(text);
            panel.expanded = true;
            tab.navigate(url, true);
            return "";
        }
    }

    Sheet {
        id: newFolderSheet
        title: qsTr("New Folder")
        message: qsTr("Name of new folder:")
        withField: true
        confirmText: qsTr("Create")
        confirmHandler: name => {
            // Invalid or taken names answer at once (the sheet stays with the reason); KIO's own error comes later.
            let refused = "";
            let answered = false;
            panel.app.makeFolder(tab.url, name, (url, error) => {
                answered = true;
                if (error !== "" && newFolderSheet.shown) {
                    refused = error;
                } else if (error !== "") {
                    panel.alert(qsTr("The folder can’t be made."), error);
                } else {
                    tab.navigate(Qt.url(url), true);
                }
            });
            return answered ? refused : "";
        }
    }

    // Replace questions and refusals.
    Sheet {
        id: alertSheet
    }

    // KIO's questions about the panel's own work (a certificate, a name that exists), as in Files (ADR-0035 D-12 a).
    KioSheets {
        id: kioSheets
        readonly property bool sheetShown: kioSheets.shownId >= 0
        prompts: panel.app.prompts ?? null
        shown: panel.manager.promptWindow === panel && !goSheet.shown && !newFolderSheet.shown && !alertSheet.shown && !menus.visible
        focusBack: panel.focusTarget()
    }

    MenuLayer {
        id: menus
    }
}
