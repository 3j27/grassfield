pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Go to Folder (⇧⌘G, macOS 27 Finder-Go-To-Folder, FP-76): a panel over the window with the path field, the rest of the
// first matching folder's name inline (Tab or → takes it), and a "Go to:" list of the matching folders (FilesApp
// completeFolder, listed off the GUI thread); the recent folders while the field is empty. Return goes to the typed
// location when it exists (a folder: itself, so "/" and "~/" open the root and the home folder; a URL: trash:/, smb://…;
// a file: its folder, the file selected); it goes to the chosen row only when the path is partial, or when an arrow key
// chose that row. Esc or a click outside closes it.
// Declare it as a child of the window's content; it fills it.
Item {
    id: root

    required property var app
    // The BrowserTab it navigates (relative paths start in its folder).
    property var tab: null
    property Item focusBack: null

    property var matches: []
    property int chosen: 0
    // An arrow key moved the choice: Return then goes to that row even when the typed path exists.
    property bool picked: false
    property string errorText: ""
    readonly property bool shown: root.visible
    readonly property bool showingRecents: field.text === ""
    readonly property var rows: root.showingRecents ? root.app.recentFolders.map(r => ({url: r.url, parts: root.partsOf(r.url), name: ""})) : root.matches
    // The rest of the chosen match's name after what is typed of it ("~/D" + "ownloads").
    readonly property string suffix: {
        if (root.showingRecents || root.matches.length === 0 || field.cursorPosition !== field.text.length)
            return "";
        const typed = field.text.substring(field.text.lastIndexOf("/") + 1);
        const name = root.matches[Math.min(root.chosen, root.matches.length - 1)].name;
        return name.toLowerCase().startsWith(typed.toLowerCase()) ? name.substring(typed.length) : "";
    }

    anchors.fill: parent
    visible: false
    z: 900

    function open(): void {
        root.errorText = "";
        root.matches = [];
        root.chosen = 0;
        root.picked = false;
        field.text = "";
        root.visible = true;
        field.forceActiveFocus();
    }

    function close(): void {
        if (root.focusBack)
            root.focusBack.forceActiveFocus();
        root.visible = false;
    }

    function partsOf(url: url): var {
        const s = String(url);
        if (s.startsWith("file://"))
            return decodeURIComponent(s.substring(7)).split("/").filter(p => p !== "");
        return [s];
    }

    // The matched start of a row's last folder name, bold (Finder).
    function typedLength(): int {
        return field.text.length - (field.text.lastIndexOf("/") + 1);
    }

    function accept(): void {
        const text = field.text.trim();
        // What is typed wins when it exists (the Finder opens "/" and "~/" themselves, not their first subfolder), unless
        // an arrow key chose a row. A file opens its folder with the file selected; a folder or a URL opens as it is.
        if (text !== "" && !root.picked) {
            const target = root.app.goToTarget(text, root.tab.url);
            if (String(target.folder) !== "") {
                root.go(target.folder);
                if (String(target.select) !== "")
                    root.tab.folder.expect(target.select, false);
                return;
            }
        }
        // A partial path completes to the chosen match (the recents, while the field is empty).
        if (root.rows.length > 0 && root.chosen >= 0 && root.chosen < root.rows.length) {
            root.go(root.rows[root.chosen].url);
            return;
        }
        if (text !== "")
            root.errorText = qsTr("The folder “%1” can’t be found.").arg(text);
    }

    function go(url: url): void {
        root.close();
        root.tab.navigate(url, true);
    }

    // Tab or → at the end: the chosen match's name completes the text.
    function complete(): bool {
        if (root.showingRecents || root.matches.length === 0)
            return false;
        const name = root.matches[Math.min(root.chosen, root.matches.length - 1)].name;
        field.text = root.app.completedText(field.text, root.tab.url, name);
        field.cursorPosition = field.text.length;
        return true;
    }

    Connections {
        target: root.app
        function onFolderCompletions(text: string, matches: var): void {
            if (text !== field.text)
                return;
            root.matches = matches;
            root.chosen = 0;
            root.picked = false;
        }
    }

    // A click outside closes it (Finder); nothing reaches the window under it.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: root.close()
        onWheel: wheel => wheel.accepted = true
    }

    Rectangle {
        id: panel
        width: Math.min(Tokens.filesGoPanelWidth, root.width - 2 * Tokens.spacingLg)
        height: Tokens.filesGoPanelHeight
        x: (root.width - width) / 2
        y: Tokens.filesToolbarHeight
        radius: Tokens.filesGoPanelRadius
        color: Appearance.colors.windowBackground
        border.width: Tokens.appsBorderWidth
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        clip: true
        Accessible.role: Accessible.Dialog
        Accessible.name: qsTr("Go to Folder")

        // Clicks inside stay inside.
        MouseArea {
            anchors.fill: parent
        }

        Item {
            id: fieldRow
            width: parent.width
            height: Tokens.filesGoFieldHeight

            TextInput {
                id: field
                TextCursor {}
                anchors.left: parent.left
                anchors.leftMargin: Tokens.filesGoFieldInset
                anchors.right: clear.left
                anchors.rightMargin: Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                clip: true
                color: Appearance.colors.text
                selectionColor: Appearance.highlight
                selectedTextColor: Appearance.highlightText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.filesGoFieldTextSize
                Accessible.role: Accessible.EditableText
                Accessible.name: qsTr("Folder path")
                onTextEdited: {
                    root.errorText = "";
                    root.picked = false;
                    if (field.text === "")
                        root.matches = [];
                    else
                        root.app.completeFolder(field.text, root.tab.url);
                }

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        root.close();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.accept();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        root.chosen = Math.min(root.chosen + 1, root.rows.length - 1);
                        root.picked = true;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        root.chosen = Math.max(root.chosen - 1, 0);
                        root.picked = true;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab || (event.key === Qt.Key_Right && field.cursorPosition === field.text.length && root.suffix !== "")) {
                        if (root.complete() || event.key === Qt.Key_Tab)
                            event.accepted = true;
                    }
                }

                // The inline completion: the rest of the chosen name, dimmed, after the caret.
                Text {
                    textFormat: Text.PlainText
                    visible: root.suffix !== ""
                    x: field.cursorRectangle.x + field.cursorRectangle.width
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.suffix
                    color: Appearance.colors.textSecondary
                    font: field.font
                }

                Text {
                    textFormat: Text.PlainText
                    visible: field.text === ""
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Folder path, ~/Documents or trash:/")
                    color: Appearance.colors.textSecondary
                    font: field.font
                }
            }

            // Clear: a filled disc with a cross (Finder).
            Rectangle {
                id: clear
                visible: field.text !== ""
                width: Tokens.filesGoClearSize
                height: width
                radius: width / 2
                anchors.right: parent.right
                anchors.rightMargin: Tokens.filesGoFieldInset
                anchors.verticalCenter: parent.verticalCenter
                color: Appearance.colors.textSecondary
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Clear")

                Icon {
                    anchors.centerIn: parent
                    name: "close-glyph"
                    size: parent.width - Tokens.spacingXs
                    color: Appearance.colors.windowBackground
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        field.text = "";
                        root.matches = [];
                        field.forceActiveFocus();
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }
        }

        Rectangle {
            anchors.top: fieldRow.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            color: Appearance.withAlpha(Appearance.colors.text, Tokens.filesGoListOpacity)

            Text {
                textFormat: Text.PlainText
                x: Tokens.filesGoRowInset + Tokens.filesGoRowTextInset
                y: Tokens.filesGoHeaderCenter - height / 2
                visible: root.rows.length > 0 || root.errorText !== ""
                text: root.errorText !== "" ? root.errorText : root.showingRecents ? qsTr("Recents") : qsTr("Go to:")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: root.errorText !== "" ? Font.Normal : Font.Bold
            }

            ListView {
                id: list
                y: Tokens.filesGoHeaderHeight
                width: parent.width
                height: parent.height - y
                clip: true
                visible: root.errorText === ""
                model: root.rows
                currentIndex: root.chosen
                boundsBehavior: Flickable.StopAtBounds
                onCurrentIndexChanged: list.positionViewAtIndex(list.currentIndex, ListView.Contain)
                Accessible.role: Accessible.List
                Accessible.name: root.showingRecents ? qsTr("Recents") : qsTr("Go to:")

                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool chosen: row.index === root.chosen
                    readonly property var parts: row.modelData.parts

                    width: list.width
                    height: Tokens.filesGoRowHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: row.parts.join(" › ")
                    Accessible.selected: row.chosen

                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: Tokens.filesGoRowInset
                        anchors.rightMargin: Tokens.filesGoRowInset
                        radius: Tokens.radiusControl
                        color: row.chosen ? Appearance.highlight : "transparent"
                    }

                    // The path, its last folder kept in view when it is too long (the start slides out on the left).
                    Item {
                        id: pathBox
                        x: Tokens.filesGoRowInset + Tokens.filesGoRowTextInset
                        width: parent.width - 2 * x
                        height: parent.height
                        clip: true

                        Row {
                            id: pathRow
                            x: Math.min(0, pathBox.width - pathRow.width)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Tokens.spacingXs

                            Repeater {
                                model: row.parts

                                delegate: Row {
                                    id: part
                                    required property string modelData
                                    required property int index
                                    readonly property bool last: part.index === row.parts.length - 1
                                    readonly property int bold: part.last && !root.showingRecents ? Math.min(root.typedLength(), part.modelData.length) : 0
                                    spacing: Tokens.spacingXs

                                    Text {
                                        textFormat: Text.PlainText
                                        visible: part.index > 0
                                        text: "›"
                                        color: row.chosen ? Appearance.highlightText : Appearance.colors.textSecondary
                                        font.family: Appearance.fontFamily
                                        font.pixelSize: Tokens.typographyBodySize
                                    }

                                    // The typed start in bold, the rest regular: two plain runs side by side (no rich text for a
                                    // folder's name).
                                    Row {
                                        spacing: 0

                                        Text {
                                            textFormat: Text.PlainText
                                            visible: part.bold > 0
                                            text: part.modelData.substring(0, part.bold)
                                            color: row.chosen ? Appearance.highlightText : Appearance.colors.text
                                            font.family: Appearance.fontFamily
                                            font.pixelSize: Tokens.typographyBodySize
                                            font.bold: true
                                        }

                                        Text {
                                            textFormat: Text.PlainText
                                            text: part.modelData.substring(part.bold)
                                            color: row.chosen ? Appearance.highlightText : Appearance.colors.text
                                            font.family: Appearance.fontFamily
                                            font.pixelSize: Tokens.typographyBodySize
                                        }
                                    }
                                }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.chosen = row.index
                        onClicked: root.go(row.modelData.url)
                    }
                }
            }
        }
    }
}
