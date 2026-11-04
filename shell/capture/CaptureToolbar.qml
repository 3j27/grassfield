pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "CaptureModel.js" as Model

// The capture toolbar's window (spec docs/specs/system-dialogs.md "Capture toolbar", ADR-0045 OC-1), one per screen, mapped
// only on the controller's screen while open. As Search, a full-screen transparent overlay that holds the keyboard (exclusive)
// and swallows the clicks around the bar (macOS: the screen is in capture mode while the toolbar shows). macOS 27's layout: a
// floating bar of the macOS 26 glass (the menus' class), centred over the Dock's band, its ends round:
//   Close | Capture Entire Screen, Capture Selected Window, Capture Selected Portion | Record Entire Screen, Record Selected
//   Portion | Options and its chevron, then Capture or Record.
// The modes are the shared ToolButton (capsules, one checked, the neutral selection on glass, a tooltip each), the action the
// shared primary Button, and Options opens the shared PopupMenu (section headers, check marks) above itself, inside this window.
// Without gpu-screen-recorder the recordings' group is not shown (OC-0 rule 3).
Variants {
    id: root

    required property var controller

    model: Quickshell.screens

    // A hairline between two groups of the bar (the toolbar's divider height, the menus' separator colour).
    component Divider: Item {
        implicitWidth: 2 * Tokens.captureToolbarSeparatorGap + Tokens.controlBorderWidth
        implicitHeight: Tokens.captureToolbarButtonHeight
        Accessible.role: Accessible.Separator
        Accessible.ignored: true

        Rectangle {
            anchors.centerIn: parent
            width: Tokens.controlBorderWidth
            height: Tokens.toolbarDividerHeight
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }
    }

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool shown: root.controller.open && root.controller.screenName === (modelData ? modelData.name : "")
        readonly property bool recordMode: Model.isRecord(root.controller.mode)
        // The Options menu is open, and where it hangs from (its bottom left: over the Options button, above the bar).
        property bool menuOpen: false
        property point menuAt: Qt.point(0, 0)
        readonly property var menuModel: menuOpen ? Model.menuModel(root.controller.mode, root.controller.options, {
            saveTo: qsTr("Save to"),
            desktop: qsTr("Desktop"),
            documents: qsTr("Documents"),
            clipboard: qsTr("Clipboard"),
            preview: qsTr("Preview"),
            timer: qsTr("Timer"),
            none: qsTr("None"),
            five: qsTr("5 Seconds"),
            ten: qsTr("10 Seconds"),
            microphone: qsTr("Microphone"),
            micNone: qsTr("None"),
            // The default input by the name the sound settings give it (macOS lists the inputs by name).
            micDefault: Audio.source ? Audio.describe(Audio.source) : qsTr("Default Input"),
            options: qsTr("Options"),
            showPointer: qsTr("Show Mouse Pointer")
        }) : []
        readonly property var modeNames: ({
                "screen": qsTr("Capture Entire Screen"),
                "window": qsTr("Capture Selected Window"),
                "selection": qsTr("Capture Selected Portion"),
                "recordScreen": qsTr("Record Entire Screen"),
                "recordSelection": qsTr("Record Selected Portion")
            })
        // The neutral selection of an item on glass (macOS 27, ADR-0039 step 12: one role with the switcher's).
        readonly property color selectedFill: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialSelectionOpacity)

        screen: modelData
        // Mapped a moment longer than it holds the keyboard: a layer destroyed while Exclusive leaves the compositor with no
        // keyboard focus.
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
        WlrLayershell.namespace: "grassfield-capture"
        // qmllint disable missing-type
        // The whole display takes input while shown; nothing once closed: the surface stays mapped a moment for the keyboard
        // release, and a click in that moment belongs to the window under it.
        mask: win.shown ? null : passThrough
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: bar
            radius: Tokens.captureToolbarHeight / 2

            // Only while the menu is open: a Loader keeps its last size once it unloads.
            Region {
                item: win.menuOpen ? menuLoader : null
                radius: Tokens.radiusMenu
            }
        }

        Region {
            id: passThrough
        }

        KeyboardRelease {
            id: release
            shown: win.shown
        }

        onShownChanged: {
            win.menuOpen = false;
            if (shown)
                keys.forceActiveFocus();
        }

        function openMenu(): void {
            const at = optionsButton.mapToItem(win.contentItem, 0, 0);
            win.menuAt = Qt.point(at.x, bar.y - Tokens.spacingSm);
            win.menuOpen = true;
        }

        function closeMenu(): void {
            if (!win.menuOpen)
                return;
            win.menuOpen = false;
            if (win.shown)
                keys.forceActiveFocus();
        }

        function applyMenu(id: string): void {
            win.closeMenu();
            root.controller.setOption(id);
        }

        // Closed but still mapped (the hold): a press the compositor delivered before the empty mask landed is swallowed here,
        // never handled by what lies under it.
        MouseArea {
            anchors.fill: parent
            z: 1000
            visible: !win.shown
            acceptedButtons: Qt.AllButtons
        }

        // Around the bar: a press closes an open menu and goes nowhere else (macOS: the screen waits for the capture).
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: win.closeMenu()
        }

        Item {
            id: keys

            focus: true
            Keys.onPressed: event => {
                event.accepted = true;
                switch (event.key) {
                case Qt.Key_Escape:
                    root.controller.hide();
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    root.controller.trigger();
                    break;
                case Qt.Key_Left:
                    root.controller.step(-1);
                    break;
                case Qt.Key_Right:
                    root.controller.step(1);
                    break;
                default:
                    event.accepted = false;
                }
            }
        }

        // A mode of the toolbar: a capsule with its glyph, checked while it is the mode; a recording mode is disabled while a
        // recording runs (the helper refuses a second one too).
        Component {
            id: modeButton

            ToolButton {
                id: button

                required property var modelData

                width: Tokens.captureToolbarButtonWidth
                height: Tokens.captureToolbarButtonHeight
                capsule: true
                radio: true
                checkable: true
                checked: root.controller.mode === button.modelData.id
                checkedColor: win.selectedFill
                enabled: !button.modelData.record || root.controller.canRecord
                iconName: button.modelData.glyph
                glyphSize: Tokens.captureToolbarIconSize
                accessibleName: win.modeNames[button.modelData.id]
                onClicked: root.controller.choose(button.modelData.id)
            }
        }

        Item {
            id: bar

            visible: win.shown
            width: row.implicitWidth + 2 * Tokens.captureToolbarPadding
            height: Tokens.captureToolbarHeight
            x: Math.round((win.width - width) / 2)
            // Above the Dock's band (where the Dock lies at the bottom), else above the display's bottom edge.
            y: win.height - Settings.dockFootprint.bottom - Tokens.captureToolbarBottomGap - height
            Accessible.role: Accessible.ToolBar
            Accessible.name: qsTr("Screenshot")

            // Swallows presses on the bar itself (between its buttons).
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: win.closeMenu()
            }

            // The bar's glass: a text surface (Options, Capture), the menus' class.
            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: Tokens.captureToolbarHeight / 2
            }

            Row {
                id: row

                anchors.centerIn: parent

                ToolButton {
                    width: Tokens.captureToolbarButtonHeight
                    height: Tokens.captureToolbarButtonHeight
                    capsule: true
                    iconName: "xmark-circle"
                    glyphSize: Tokens.captureToolbarCloseIconSize
                    accessibleName: qsTr("Close")
                    onClicked: root.controller.hide()
                }

                Divider {}

                Row {
                    spacing: Tokens.captureToolbarButtonSpacing

                    Repeater {
                        model: Model.MODES.filter(m => !m.record)
                        delegate: modeButton
                    }
                }

                Divider {
                    visible: root.controller.recorder
                }

                Row {
                    visible: root.controller.recorder
                    spacing: Tokens.captureToolbarButtonSpacing

                    Repeater {
                        model: Model.MODES.filter(m => m.record)
                        delegate: modeButton
                    }
                }

                Divider {}

                ToolButton {
                    id: optionsButton

                    width: optionsLabel.implicitWidth + 2 * Tokens.captureToolbarTextPadding
                    height: Tokens.captureToolbarButtonHeight
                    capsule: true
                    checkedColor: win.selectedFill
                    // Pressed in while its menu is open; its name is its label (no tooltip, as a text button).
                    checked: win.menuOpen
                    accessibleName: qsTr("Options")
                    tooltip: ""
                    onClicked: {
                        if (win.menuOpen)
                            win.closeMenu();
                        else
                            win.openMenu();
                    }

                    Row {
                        id: optionsLabel

                        anchors.centerIn: parent
                        spacing: Tokens.captureToolbarChevronGap

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: qsTr("Options")
                            color: optionsButton.foreground
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.letterSpacing: Appearance.tracking(Tokens.typographyBodySize)
                        }

                        Icon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevron-down"
                            size: Tokens.captureToolbarChevronSize
                        }
                    }
                }

                Item {
                    width: Tokens.captureToolbarSeparatorGap
                    height: Tokens.captureToolbarButtonHeight
                }

                // The action: Capture, or Record in a recording mode (the default button, as macOS draws it).
                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    primary: true
                    capsule: true
                    focusPolicy: Qt.NoFocus
                    text: win.recordMode ? qsTr("Record") : qsTr("Capture")
                    enabled: !win.recordMode || root.controller.canRecord
                    onClicked: root.controller.trigger()
                }
            }
        }

        // The Options menu, inside this window: it already covers the display and holds the keyboard. A press outside the
        // menu closes it and is swallowed.
        MouseArea {
            anchors.fill: parent
            z: 900
            visible: win.menuOpen
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => {
                const menu = menuLoader.item as PopupMenu;
                if (!menu || !menu.containsPoint(mouse.x, mouse.y))
                    win.closeMenu();
            }
        }

        Loader {
            id: menuLoader

            readonly property real menuWidth: (item as Item)?.width ?? 0
            readonly property real menuHeight: (item as Item)?.height ?? 0
            // Above the Options button, its left edge under the button's (kept inside the display).
            readonly property point placed: MenuPlace.place({x: win.menuAt.x, y: win.menuAt.y - menuHeight}, {w: menuWidth, h: menuHeight}, {w: win.width, h: win.height}, Tokens.panelPopupMargin)

            z: 901
            x: placed.x
            y: placed.y
            active: win.menuOpen
            sourceComponent: PopupMenu {
                bounds: win.contentItem
                model: win.menuModel
                accessibleName: qsTr("Options")
                onActivated: item => win.applyMenu(item.id)
                onCloseRequested: win.closeMenu()
            }
            onLoaded: (item as Item).forceActiveFocus()
        }
    }
}
