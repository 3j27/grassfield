pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services

// Search window, one per screen, mapped only on the controller's screen while open. Full-screen
// transparent layer-shell overlay (a click outside closes), keyboard exclusive while open.
Variants {
    id: root

    required property var controller

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool shown: root.controller.open && root.controller.screenName === modelData.name
        readonly property real maxResults: height * Tokens.searchMaxHeightFraction - Tokens.searchFieldHeight

        screen: modelData
        // Mapped a moment longer than it holds the keyboard (the fade-out): a layer destroyed while Exclusive leaves the
        // compositor with no keyboard focus.
        visible: release.mapped
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-search"
        // qmllint disable missing-type
        // Everything except the menu bar strip receives input.
        mask: Region {
            width: win.width
            height: win.height

            Region {
                width: win.width
                height: Tokens.menubarHeight
                intersection: Intersection.Subtract
            }
        }
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: panel
            radius: Tokens.radiusSearch
        }

        KeyboardRelease {
            id: release
            shown: win.shown
        }

        onShownChanged: {
            if (shown) {
                field.text = root.controller.query;
                field.forceActiveFocus();
                firstFrame.done = false;
            }
        }

        // Logs open -> first rendered frame once per opening.
        Connections {
            id: firstFrame

            property bool done: true

            target: win.shown ? panel.Window.window : null

            function onFrameSwapped(): void {
                if (done)
                    return;
                done = true;
                console.info("grassfield-shell: search open->visible", Date.now() - root.controller.openStartMs, "ms");
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: root.controller.hide()
        }

        Item {
            id: panel

            readonly property bool hasResults: root.controller.rows.length > 0

            x: (win.width - width) / 2
            y: win.height * Tokens.searchTopFraction
            width: Math.min(Tokens.searchWidth, win.width - 2 * Tokens.searchEdgeMargin)
            height: Tokens.searchFieldHeight + (hasResults ? Math.min(list.contentHeight + 2 * Tokens.spacingSm, win.maxResults) : 0)
            opacity: win.shown ? 1 : 0
            Accessible.role: Accessible.Pane
            Accessible.name: qsTr("Search")

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            Behavior on height {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                    easing.type: Easing.OutCubic
                }
            }

            // Swallows clicks on the panel itself.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            Material {
                anchors.fill: parent
                radius: Tokens.radiusSearch
            }

            Icon {
                id: glass
                x: Tokens.spacingLg
                y: (Tokens.searchFieldHeight - height) / 2
                size: Tokens.searchFieldIconSize
                name: "search"
                color: Appearance.colors.textSecondary
            }

            TextInput {
                id: field
                TextCursor {}
                x: glass.x + glass.width + Tokens.spacingMd
                y: 0
                width: panel.width - x - Tokens.spacingLg
                height: Tokens.searchFieldHeight
                verticalAlignment: TextInput.AlignVCenter
                color: Appearance.colors.text
                selectionColor: Appearance.colors.accent
                selectedTextColor: Appearance.colors.accentText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.searchFieldSize
                clip: true
                focus: true
                // No blinking caret in the visual fixture: a captured frame must not depend on the blink phase.
                cursorVisible: activeFocus && !VisualFixtures.active
                Accessible.role: Accessible.EditableText
                Accessible.name: qsTr("Search")
                Accessible.description: qsTr("Type to search applications, files, calculations and commands")

                onTextChanged: {
                    if (!win.shown)
                        return;
                    root.controller.keyStartMs = Date.now();
                    root.controller.setQuery(text);
                    root.controller.keyStartMs = 0;
                }

                Keys.onPressed: event => {
                    const c = root.controller;
                    const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
                    event.accepted = true;
                    switch (event.key) {
                    case Qt.Key_Down:
                        c.move(1);
                        break;
                    case Qt.Key_Up:
                        c.move(-1);
                        break;
                    case Qt.Key_Tab:
                        // Some injectors (wtype) deliver Shift+Tab as Tab with Shift held.
                        c.moveGroup((event.modifiers & Qt.ShiftModifier) !== 0 ? -1 : 1);
                        break;
                    case Qt.Key_Backtab:
                        c.moveGroup(-1);
                        break;
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                        c.activateSelected(ctrl);
                        break;
                    case Qt.Key_Escape:
                        if (field.text !== "")
                            field.text = "";
                        else
                            c.hide();
                        break;
                    default:
                        event.accepted = false;
                    }
                }

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: field.text === "" && field.preeditText === ""
                    text: qsTr("Search")
                    textFormat: Text.PlainText
                    color: Appearance.colors.textSecondary
                    font: field.font
                }
            }

            Rectangle {
                visible: panel.hasResults
                x: Tokens.spacingLg
                y: Tokens.searchFieldHeight - 1
                width: panel.width - 2 * Tokens.spacingLg
                height: 1
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            ListView {
                id: list
                x: Tokens.spacingSm
                y: Tokens.searchFieldHeight + Tokens.spacingSm
                width: panel.width - 2 * Tokens.spacingSm
                height: panel.height - y - Tokens.spacingSm
                clip: true
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds
                model: root.controller.rows
                currentIndex: {
                    const sel = root.controller.selected;
                    const r = root.controller.rows;
                    for (let i = 0; i < r.length; i++) {
                        if (!r[i].header && r[i].itemIndex === sel)
                            return i;
                    }
                    return -1;
                }
                onCurrentIndexChanged: {
                    if (currentIndex < 0)
                        return;
                    // Show the group header above the first item of a group.
                    const r = root.controller.rows;
                    const header = currentIndex > 0 && r[currentIndex - 1].header ? currentIndex - 1 : currentIndex;
                    positionViewAtIndex(header, ListView.Contain);
                    positionViewAtIndex(currentIndex, ListView.Contain);
                }

                delegate: Item {
                    id: row

                    required property var modelData
                    required property int index

                    readonly property bool isHeader: modelData.header
                    readonly property bool selected: !isHeader && modelData.itemIndex === root.controller.selected
                    readonly property var info: isHeader ? ({}) : modelData.item

                    width: list.width
                    height: isHeader ? Tokens.searchHeaderHeight : Tokens.searchRowHeight
                    Accessible.role: isHeader ? Accessible.StaticText : Accessible.ListItem
                    Accessible.name: isHeader ? modelData.title : info.title + ", " + info.subtitle
                    Accessible.selected: selected
                    Accessible.onPressAction: root.controller.activate(info, false)

                    Text {
                        visible: row.isHeader
                        x: Tokens.spacingMd
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Tokens.spacingXs
                        text: row.isHeader ? row.modelData.title : ""
                        textFormat: Text.PlainText
                        color: Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                        font.weight: Tokens.typographyMenuBoldWeight
                    }

                    Rectangle {
                        visible: row.selected
                        anchors.fill: parent
                        radius: Tokens.radiusMenu
                        color: Appearance.colors.accent
                    }

                    Item {
                        id: iconBox
                        visible: !row.isHeader
                        x: Tokens.spacingMd
                        anchors.verticalCenter: parent.verticalCenter
                        width: Tokens.searchRowIconSize
                        height: Tokens.searchRowIconSize

                        TintedIcon {
                            anchors.fill: parent
                            size: Tokens.searchRowIconSize
                            oversample: Tokens.searchIconOversample
                            overAccent: row.selected
                            visible: !row.isHeader && row.info.iconSource !== undefined
                            source: !row.isHeader && row.info.iconSource !== undefined ? row.info.iconSource : ""
                            asynchronous: true
                        }

                        Icon {
                            anchors.centerIn: parent
                            visible: !row.isHeader && row.info.glyph !== undefined
                            size: Tokens.searchRowIconSize * Tokens.searchGlyphScale
                            name: !row.isHeader && row.info.glyph !== undefined ? row.info.glyph : ""
                            color: row.selected ? Appearance.colors.accentText : Appearance.colors.text
                        }

                        Rectangle {
                            anchors.fill: parent
                            visible: !row.isHeader && row.info.badge !== undefined
                            radius: Tokens.radiusControl
                            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

                            Text {
                                anchors.centerIn: parent
                                text: !row.isHeader && row.info.badge !== undefined ? row.info.badge : ""
                                textFormat: Text.PlainText
                                color: row.selected ? Appearance.colors.accentText : Appearance.colors.text
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyTitleSize
                            }
                        }
                    }

                    Column {
                        visible: !row.isHeader
                        anchors {
                            left: iconBox.right
                            leftMargin: Tokens.spacingMd
                            right: parent.right
                            rightMargin: Tokens.spacingMd
                            verticalCenter: parent.verticalCenter
                        }

                        Text {
                            width: parent.width
                            text: row.isHeader ? "" : row.info.title
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: row.selected ? Appearance.colors.accentText : Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: row.info.kind === "calc" ? Tokens.typographyTitleSize : Tokens.typographyBodySize
                            font.weight: Tokens.typographyMenuWeight
                        }

                        Text {
                            width: parent.width
                            text: row.isHeader ? "" : row.info.subtitle
                            textFormat: Text.PlainText
                            elide: Text.ElideMiddle
                            color: row.selected ? Appearance.withAlpha(Appearance.colors.accentText, Tokens.searchSelectedSubtitleOpacity) : Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: !row.isHeader
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onPositionChanged: root.controller.selected = row.modelData.itemIndex
                        onClicked: root.controller.activate(row.info, false)
                    }
                }
            }
        }
    }
}
