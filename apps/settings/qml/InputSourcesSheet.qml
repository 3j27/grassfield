pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Keyboard.js" as Keyboard

// Keyboard > Input Sources > Edit…: the layouts in use, the first one at login; + adds one (LayoutPickerSheet, through Main.qml),
// − removes the selected one (the last one stays), the arrows move it up or down. Each change goes back to the page at once
// (`changed`), which writes keyboard.lua; with two or more, Ctrl+Space selects the next (input.lua).
Sheet {
    id: root

    property var sources: []
    property var layouts: ({names: {}, all: []})
    property int selected: 0

    signal changed(var sources)
    signal addRequested(var layouts, var sources)

    title: qsTr("Input Sources")
    message: root.sources.length > 1 ? qsTr("Press Control-Space to select the next input source.") : qsTr("Add an input source to type in another layout.")
    confirmText: qsTr("Done")
    showCancel: false

    function openWith(list: var, layouts: var): void {
        root.sources = list;
        root.layouts = layouts;
        root.selected = 0;
        root.open();
    }

    function set(list: var): void {
        root.sources = list;
        root.selected = Math.max(0, Math.min(root.selected, list.length - 1));
        root.changed(list);
    }

    // LayoutPickerSheet's answer.
    function add(source: var): void {
        if (root.sources.some(s => s.layout === source.layout && s.variant === source.variant) || root.sources.length >= Keyboard.MAX_LAYOUTS)
            return;
        root.set(root.sources.concat([{layout: source.layout, variant: source.variant}]));
        root.selected = root.sources.length - 1;
    }

    function move(by: int): void {
        const i = root.selected, j = i + by;
        if (j < 0 || j >= root.sources.length)
            return;
        const list = root.sources.slice();
        const s = list[i];
        list[i] = list[j];
        list[j] = s;
        root.selected = j;
        root.set(list);
    }

    SettingsGroup {
        Item {
            id: list
            width: parent.width
            height: Math.max(1, root.sources.length) * Tokens.settingsRowHeight
            activeFocusOnTab: true
            Accessible.role: Accessible.List
            Accessible.name: root.title

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                    const by = event.key === Qt.Key_Up ? -1 : 1;
                    if (event.modifiers & Qt.AltModifier)
                        root.move(by);
                    else
                        root.selected = Math.max(0, Math.min(root.sources.length - 1, root.selected + by));
                    event.accepted = true;
                }
            }

            Repeater {
                model: root.sources

                delegate: Item {
                    id: entry

                    required property var modelData
                    required property int index
                    readonly property bool isSelected: entry.index === root.selected

                    y: entry.index * Tokens.settingsRowHeight
                    width: list.width
                    height: Tokens.settingsRowHeight
                    Accessible.role: Accessible.ListItem
                    Accessible.name: Keyboard.sourceName(entry.modelData, root.layouts.names)
                    Accessible.selected: entry.isSelected

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: Tokens.spacingXs
                        visible: entry.isSelected
                        radius: Tokens.settingsNavTileRadius
                        color: list.activeFocus ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.settingsSoundTableSelectionOpacity)
                    }

                    Text {
                        textFormat: Text.PlainText
                        x: Tokens.settingsRowInset
                        width: parent.width - 2 * Tokens.settingsRowInset
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: entry.Accessible.name
                        color: entry.isSelected && list.activeFocus ? Appearance.colors.selectionText : Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.selected = entry.index;
                            list.forceActiveFocus(Qt.MouseFocusReason);
                        }
                    }
                }
            }
        }

        ListFooter {
            canAdd: root.sources.length < Keyboard.MAX_LAYOUTS
            canRemove: root.sources.length > 1
            addName: qsTr("Add an input source")
            removeName: qsTr("Remove the selected input source")
            onAddClicked: root.addRequested(root.layouts, root.sources)
            onRemoveClicked: root.set(root.sources.filter((s, i) => i !== root.selected))
        }
    }
}
