pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import "../services/EmojiLogic.js" as Logic

// Emoji & Symbols (ADR-0045 OC-3; docs/specs/clipboard.md ES-2, ES-5, ES-6): macOS 27's compact Character Viewer, popup kind
// "emoji" of the Overlay, opened by services/Emoji at the pointer. From the top: the search field (it keeps the focus: typing
// searches), the grid of glyphs under their section titles (Recently Used, then macOS's categories; a search shows its results
// as one untitled section) and the category bar (a glyph per section, the one in view checked; a click scrolls there). The
// arrows, Page Up and Page Down, Tab and Shift+Tab move the keyboard selection, Return inserts it, a click inserts the glyph
// under the pointer (Emoji.choose); Esc clears the search, then closes. Glyphs are drawn as plain text.
FocusScope {
    id: root

    property string query: ""
    // The keyboard selection: a glyph's index in the whole grid (EmojiLogic.rows), -1 for none.
    property int current: -1
    readonly property bool searching: root.query.trim() !== ""
    readonly property int columns: Tokens.emojiColumns
    // The sections of an empty search (the category bar's too), and the ones the grid shows now.
    readonly property var baseSections: Logic.sections(Emoji.list, Emoji.groups, Emoji.recents, Emoji.titles)
    readonly property var shownSections: root.searching ? [
            {
                id: "results",
                title: "",
                items: Logic.search(Emoji.list, Emoji.groups, root.query, Emoji.titles)
            }
        ] : root.baseSections
    readonly property var rowList: Logic.rows(root.shownSections, root.columns, !root.searching)
    readonly property var lengths: root.shownSections.map(s => s.items.length)
    readonly property int total: root.lengths.reduce((a, b) => a + b, 0)
    // The section whose rows are at the top of the grid (the category bar checks its button); the last one once the grid is
    // scrolled to its end; -1 while searching.
    readonly property int topSection: {
        if (root.searching || root.rowList.length === 0)
            return -1;
        if (grid.contentHeight > grid.height && grid.atYEnd)
            return root.rowList[root.rowList.length - 1].section;
        return Logic.sectionOfRow(root.rowList, grid.indexAt(grid.width / 2, grid.contentY + Tokens.spacingXs));
    }

    width: 2 * Tokens.emojiPadding + root.columns * Tokens.emojiCellSize
    height: Tokens.emojiHeight
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Emoji & Symbols")

    // Esc in an empty field (the field clears a search first, SearchField).
    Keys.onEscapePressed: Popups.close()

    function setQuery(text: string): void {
        root.query = text;
        // A search selects its first result (Return inserts it); an empty search selects nothing until a key moves.
        root.current = root.searching && root.total > 0 ? 0 : -1;
        grid.positionViewAtBeginning();
    }

    function moveBy(key: string): void {
        const pageRows = Math.max(1, Math.floor(grid.height / Tokens.emojiCellSize));
        root.current = Logic.move(root.lengths, root.columns, root.current, key, pageRows);
        root.reveal(root.current);
    }

    // The row of glyph `index` in view, and its section's title with it when it is the section's first row.
    function reveal(index: int): void {
        const r = Logic.rowOf(root.rowList, index);
        if (r < 0)
            return;
        if (r > 0 && root.rowList[r - 1].kind === "header" && root.rowList[r - 1].start === root.rowList[r].start)
            grid.positionViewAtIndex(r - 1, ListView.Contain);
        grid.positionViewAtIndex(r, ListView.Contain);
    }

    function glyphAt(index: int): string {
        const r = Logic.rowOf(root.rowList, index);
        return r < 0 ? "" : root.rowList[r].items[index - root.rowList[r].start];
    }

    function chooseCurrent(): void {
        const glyph = root.glyphAt(root.current);
        if (glyph !== "")
            Emoji.choose(glyph);
    }

    // A category of the bar: the grid shows its title at the top (a search is cleared first).
    function goTo(section: int): void {
        if (root.searching)
            field.text = "";
        Qt.callLater(() => {
            const r = Logic.sectionRow(root.rowList, section);
            if (r >= 0)
                grid.positionViewAtIndex(r, ListView.Beginning);
        });
    }

    // Swallows clicks on the popover itself (the Overlay closes on a click outside it).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
    }

    Material {
        anchors.fill: parent
        glassClass: "menu"
        radius: Tokens.emojiRadius
    }

    SearchField {
        id: field
        x: Tokens.emojiPadding
        y: Tokens.emojiPadding
        width: root.width - 2 * Tokens.emojiPadding
        focus: true
        enabled: Emoji.state !== "missing"
        Accessible.name: qsTr("Search")
        onTextChanged: root.setQuery(text)

        // The grid's keys go to the grid while the field keeps the typing (macOS); Esc is the field's (it clears, then lets the
        // popover close).
        Keys.onPressed: event => {
            const key = Logic.keyName(event.key, (event.modifiers & Qt.ShiftModifier) !== 0);
            if (key !== "") {
                root.moveBy(key);
                event.accepted = true;
                return;
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.chooseCurrent();
                event.accepted = true;
            }
        }
    }

    ListView {
        id: grid
        x: Tokens.emojiPadding
        y: field.y + field.height + Tokens.emojiSearchGap
        width: root.columns * Tokens.emojiCellSize
        height: root.height - y - Tokens.emojiBarHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.rowList
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Emoji grid")

        ScrollBar.vertical: ScrollBar {}

        delegate: Item {
            id: row

            required property var modelData

            readonly property bool header: row.modelData.kind === "header"

            width: grid.width
            height: row.header ? Tokens.emojiHeaderHeight : Tokens.emojiCellSize

            // A section's title (macOS 27: small, bold, in the secondary colour), aligned with the selection squares.
            Text {
                visible: row.header
                x: Tokens.emojiCellInset
                width: row.width - 2 * Tokens.emojiCellInset
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: row.header ? row.modelData.title : ""
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                font.letterSpacing: Appearance.tracking(Tokens.typographyCaptionSize)
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Row {
                visible: !row.header

                Repeater {
                    model: row.header ? [] : row.modelData.items

                    delegate: Item {
                        id: cell

                        required property string modelData
                        required property int index

                        readonly property int flat: row.modelData.start + cell.index
                        readonly property bool selected: cell.flat === root.current

                        width: Tokens.emojiCellSize
                        height: Tokens.emojiCellSize
                        Accessible.role: Accessible.Button
                        Accessible.name: cell.modelData
                        Accessible.selected: cell.selected
                        Accessible.onPressAction: Emoji.choose(cell.modelData)

                        // The keyboard selection in the accent; the pointer's square neutral.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: Tokens.emojiCellInset
                            radius: Tokens.emojiCellRadius
                            color: cell.selected ? Appearance.highlight : cellMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                        }

                        Text {
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: cell.modelData
                            // A glyph drawn as text (a symbol without colour) takes the text colour of its square.
                            color: cell.selected ? Appearance.highlightText : Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.emojiGlyphSize
                            Accessible.ignored: true
                        }

                        MouseArea {
                            id: cellMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton
                            onClicked: Emoji.choose(cell.modelData)
                        }
                    }
                }
            }
        }
    }

    // What the grid says instead of glyphs: the list is missing (ES-3), or a search found nothing (ES-5).
    Text {
        x: grid.x
        y: grid.y
        width: grid.width
        height: grid.height
        visible: Emoji.state === "missing" || (Emoji.state === "ready" && root.searching && root.total === 0)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: Emoji.state === "missing" ? qsTr("Emoji list not available") : qsTr("No Results")
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        font.letterSpacing: Appearance.tracking(Tokens.typographyBodySize)
    }

    // The category bar (macOS 27: the sections' glyphs along the bottom edge, spread over the width).
    Row {
        id: bar

        readonly property int count: root.baseSections.length

        x: Tokens.emojiPadding
        y: root.height - Tokens.emojiBarHeight + (Tokens.emojiBarHeight - Tokens.emojiBarButtonSize) / 2
        spacing: bar.count > 1 ? (root.width - 2 * Tokens.emojiPadding - bar.count * Tokens.emojiBarButtonSize) / (bar.count - 1) : 0
        Accessible.role: Accessible.PageTabList
        Accessible.name: qsTr("Categories")

        Repeater {
            model: root.baseSections

            delegate: ToolButton {
                required property var modelData
                required property int index

                iconName: Logic.ICONS[modelData.id] || Logic.ICONS.all
                accessibleName: modelData.title
                checkable: true
                radio: true
                checked: root.topSection === index
                buttonSize: Tokens.emojiBarButtonSize
                glyphSize: Tokens.emojiBarGlyphSize
                onClicked: root.goTo(index)
            }
        }
    }
}
