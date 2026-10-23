pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.notifications
import qs.services
import qs.overlay.controlcenter
import "controlcenter/Model.js" as Model

// Quick Settings (spec controlcenter.md; internal name Control Center): floating glass modules on a
// 4-column grid, the macOS model. Every module is its own frosted surface (no shared panel): the
// Overlay window reads `surfaces` and gives each one a blur region. Wi-Fi, Bluetooth and Airplane
// Mode are 2x1 capsules at the left; Do Not Disturb and Now Playing (2x2, only while a player runs)
// sit at the right (the modules are declared in row order, so Tab follows rows, not columns); Display, Keyboard Brightness and Sound are 4x1 slider modules; Appearance is a
// capsule. Opening Wi-Fi, Bluetooth, Sound or Appearance replaces the grid with one detail module
// (back button in its header); Esc goes back, then closes. Values come live from the services.
FocusScope {
    id: root

    // "", "wifi", "bluetooth", "sound" or "appearance".
    property string expanded: ""
    // Shown while a GRASSFIELD_DEV session suppresses a change to the owner's machine.
    property bool devNote: false
    // Text of the note capsule: "dev: not applied" for the dev guard, or why Airplane Mode used its fallback.
    property string noteText: qsTr("dev: not applied")

    readonly property real cell: Tokens.quicksettingsCell
    readonly property real gap: Tokens.quicksettingsGap
    readonly property real pitch: cell + gap
    readonly property real pad: Tokens.quicksettingsPadding
    // Inset of the icon disk inside a capsule (the disk is vertically centred, so it is centred in a 1x1 too).
    readonly property real diskInset: (cell - Tokens.quicksettingsIconDisk) / 2
    readonly property real groupHeight: 3 * cell + 2 * gap
    readonly property real gridBottom: sliders.height > 0 ? sliders.y + sliders.height : groupHeight
    readonly property real bodyHeight: expanded === "" ? gridBottom : detail.height

    // The visible glass surfaces, for the Overlay's blur regions.
    readonly property var surfaces: [wifi, bluetooth, airplane, dnd, nowPlaying, appearanceSide, display, keyboard, sound, appearanceBottom, detail, note].filter(m => m.visible)

    function toggleSection(id: string): void {
        if (expanded === id)
            collapse();
        else
            open(id);
    }

    function open(id: string): void {
        expanded = id;
        Qt.callLater(() => back.forceActiveFocus());
    }

    function collapse(): void {
        const id = expanded;
        expanded = "";
        Qt.callLater(() => {
            const target = id === "wifi" ? wifiRow : id === "bluetooth" ? bluetoothRow : id === "sound" ? soundChevron : appearanceSide.visible ? appearanceSideRow : appearanceBottomRow;
            target.forceActiveFocus();
        });
    }

    function showDevNote(text: string): void {
        noteText = text ? text : qsTr("dev: not applied");
        devNote = true;
        noteTimer.restart();
    }

    function titleOf(id: string): string {
        switch (id) {
        case "wifi":
            return qsTr("Wi-Fi");
        case "bluetooth":
            return qsTr("Bluetooth");
        case "sound":
            return qsTr("Sound");
        case "appearance":
            return qsTr("Appearance");
        }
        return "";
    }

    width: Tokens.panelControlCenterWidth
    height: bodyHeight + (devNote ? gap + note.height : 0)
    Accessible.role: Accessible.Window
    Accessible.name: qsTr("Quick Settings")

    Keys.onEscapePressed: {
        if (expanded !== "")
            collapse();
        else
            Popups.close();
    }

    // Keyboard (macOS model): Up/Down move focus to the module above or below, Left/Right to the control beside;
    // a slider changes with Left/Right only while it has focus (verticalKeys is off for them), so walking the
    // grid with Down never changes a value. Keys a control did not handle reach these handlers.
    Keys.onUpPressed: event => event.accepted = gridNavigate(root.Window.window ? root.Window.window.activeFocusItem : null, 0, -1)
    Keys.onDownPressed: event => event.accepted = gridNavigate(root.Window.window ? root.Window.window.activeFocusItem : null, 0, 1)
    // Left/Right: the control beside; at the edge of the grid the menu bar's previous or next status menu opens (macOS
    // Ctrl+F8 walk), and Left in an expanded section collapses it first.
    Keys.onLeftPressed: event => {
        if (expanded !== "") {
            collapse();
        } else if (!gridNavigate(root.Window.window ? root.Window.window.activeFocusItem : null, -1, 0)) {
            Popups.stepMenu(-1);
        }
        event.accepted = true;
    }
    Keys.onRightPressed: event => {
        if (expanded === "" && !gridNavigate(root.Window.window ? root.Window.window.activeFocusItem : null, 1, 0))
            Popups.stepMenu(1);
        event.accepted = true;
    }

    function collectTargets(node: Item, out: var): void {
        for (const child of node.children) {
            if (!child.visible)
                continue;
            if (child.activeFocusOnTab && child.enabled)
                out.push(child);
            collectTargets(child, out);
        }
    }

    // Moves focus from `from` towards (dx, dy) over the visible focusable controls (Model.navTarget).
    function gridNavigate(from: Item, dx: int, dy: int): bool {
        const targets = [];
        collectTargets(root, targets);
        const rects = targets.map(t => {
            const p = t.mapToItem(root, 0, 0);
            return {x: p.x, y: p.y, w: t.width, h: t.height};
        });
        const i = Model.navTarget(rects, targets.indexOf(from), dx, dy);
        if (i < 0)
            return false;
        targets[i].forceActiveFocus();
        return true;
    }

    // Scanning only while the list is on screen.
    readonly property bool scanWanted: expanded === "wifi" && Connectivity.wifiEnabled
    onScanWantedChanged: Connectivity.setScanning(scanWanted)

    Component.onDestruction: {
        Connectivity.setScanning(false);
    }

    Timer {
        id: noteTimer
        interval: Tokens.panelCcNoteTimeout
        onTriggered: root.devNote = false
    }

    Connections {
        target: Connectivity
        function onDevSuppressed() {
            root.showDevNote();
        }
        function onAirplaneFallback(why) {
            root.showDevNote(why);
        }
    }

    Connections {
        target: BluetoothState
        function onDevSuppressed() {
            root.showDevNote();
        }
    }

    Connections {
        target: Audio
        function onDevSuppressed() {
            root.showDevNote();
        }
    }

    // Bold title of a slider module.
    component ModuleTitle: Label {
        x: root.pad
        y: Tokens.spacingSm
        width: parent.width - 2 * root.pad
        font.pixelSize: Tokens.quicksettingsTitleSize
        font.weight: Tokens.typographyMenuBoldWeight
    }

    Item {
        id: grid
        width: parent.width
        height: root.gridBottom
        visible: root.expanded === ""

        Module {
            id: wifi
            cols: 2

            RadioRow {
                id: wifiRow
                width: parent.width
                height: parent.height
                inset: root.diskInset
                iconName: Connectivity.wifiEnabled ? Connectivity.iconName === "wifi-off" ? "wifi-3" : Connectivity.iconName : "wifi-off"
                title: qsTr("Wi-Fi")
                subtitle: !Connectivity.available || Connectivity.wifiDevice === null ? qsTr("Unavailable")
                    : !Connectivity.wifiEnabled ? qsTr("Off")
                    : Connectivity.wifiConnected ? Connectivity.wifiConnected.name : qsTr("Not connected")
                on: Connectivity.wifiEnabled && Connectivity.wifiDevice !== null
                available: Connectivity.available && Connectivity.wifiDevice !== null
                expandable: true
                expanded: root.expanded === "wifi"
                onToggled: Connectivity.toggleWifi(!Connectivity.wifiEnabled)
                onExpandToggled: root.toggleSection("wifi")
            }
        }

        Module {
            id: dnd
            x: 2 * root.pitch
            cols: 2

            RadioRow {
                width: parent.width
                height: parent.height
                inset: root.diskInset
                iconName: "moon"
                title: qsTr("Do Not Disturb")
                subtitle: Notifications.dnd ? qsTr("On") : qsTr("Off")
                on: Notifications.dnd
                onToggled: Notifications.setDnd(!Notifications.dnd)
            }
        }

        Module {
            id: bluetooth
            y: root.pitch
            cols: 2

            RadioRow {
                id: bluetoothRow
                width: parent.width
                height: parent.height
                inset: root.diskInset
                iconName: "bluetooth"
                title: qsTr("Bluetooth")
                subtitle: BluetoothState.description
                on: BluetoothState.enabled
                available: BluetoothState.available
                expandable: true
                expanded: root.expanded === "bluetooth"
                onToggled: BluetoothState.setEnabled(!BluetoothState.enabled)
                onExpandToggled: root.toggleSection("bluetooth")
            }
        }

        NowPlaying {
            id: nowPlaying
            visible: Media.available
            x: 2 * root.pitch
            y: root.pitch
        }

        // Appearance sits beside Do Not Disturb while there is no player, below the sliders otherwise.
        Module {
            id: appearanceSide
            visible: !Media.available
            x: 2 * root.pitch
            y: root.pitch
            cols: 2

            RadioRow {
                id: appearanceSideRow
                width: parent.width
                height: parent.height
                inset: root.diskInset
                iconName: Appearance.dark ? "moon" : "sun"
                title: qsTr("Appearance")
                subtitle: Model.appearanceLabel(Settings.appearance, {light: qsTr("Light"), dark: qsTr("Dark"), auto: qsTr("Auto")})
                on: root.expanded === "appearance"
                expandable: true
                expanded: root.expanded === "appearance"
                onToggled: root.toggleSection("appearance")
                onExpandToggled: root.toggleSection("appearance")
            }
        }

        Module {
            id: airplane
            y: 2 * root.pitch
            // Full width while no player takes the 2x2 slot at the right.
            cols: Media.available ? 2 : 4

            RadioRow {
                width: parent.width
                height: parent.height
                inset: root.diskInset
                iconName: "airplane"
                title: qsTr("Airplane Mode")
                subtitle: Connectivity.airplane ? qsTr("Wi-Fi and Bluetooth off") : qsTr("Off")
                on: Connectivity.airplane
                available: Connectivity.airplaneAvailable
                onToggled: Connectivity.setAirplane(!Connectivity.airplane)
            }
        }

        Column {
            id: sliders
            y: root.groupHeight + root.gap
            width: parent.width
            spacing: root.gap

            Module {
                id: display
                visible: Brightness.available
                cols: 4
                radius: Tokens.quicksettingsRadiusSlider
                height: Tokens.quicksettingsSliderModuleHeight

                ModuleTitle {
                    text: qsTr("Display")
                }

                Row {
                    x: root.pad
                    y: parent.height - height - Tokens.spacingXs
                    width: parent.width - 2 * root.pad
                    spacing: Tokens.spacingSm
                    height: Tokens.controlSliderHeight

                    Icon {
                        id: displayIcon
                        anchors.verticalCenter: parent.verticalCenter
                        size: Tokens.menuIconSize
                        name: "display"
                    }

                    Slider {
                        id: displaySlider
                        trackHeight: Tokens.controlSliderTrackCompact
                        verticalKeys: false
                        width: parent.width - displayIcon.width - parent.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        accessibleName: qsTr("Display brightness")
                        value: Brightness.level
                        onMoved: v => {
                            // A refused change (dev guard, no device) snaps the slider back to the real value.
                            if (!Brightness.setLevel(v)) {
                                displaySlider.reset();
                                if (Brightness.devSession)
                                    root.showDevNote();
                            }
                        }
                    }
                }
            }

            Module {
                id: keyboard
                visible: Brightness.kbdAvailable
                cols: 4
                radius: Tokens.quicksettingsRadiusSlider
                height: Tokens.quicksettingsSliderModuleHeight

                ModuleTitle {
                    text: qsTr("Keyboard Brightness")
                }

                Row {
                    x: root.pad
                    y: parent.height - height - Tokens.spacingXs
                    width: parent.width - 2 * root.pad
                    spacing: Tokens.spacingSm
                    height: Tokens.controlSliderHeight

                    Icon {
                        id: kbdIcon
                        anchors.verticalCenter: parent.verticalCenter
                        size: Tokens.menuIconSize
                        name: "keyboard"
                    }

                    Slider {
                        id: kbdSlider
                        trackHeight: Tokens.controlSliderTrackCompact
                        verticalKeys: false
                        width: parent.width - kbdIcon.width - parent.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        accessibleName: qsTr("Keyboard brightness")
                        value: Brightness.kbdLevel
                        onMoved: v => {
                            if (!Brightness.setKbdLevel(v)) {
                                kbdSlider.reset();
                                if (Brightness.devSession)
                                    root.showDevNote();
                            }
                        }
                    }
                }
            }

            Module {
                id: sound
                visible: Audio.ready
                cols: 4
                radius: Tokens.quicksettingsRadiusSlider
                height: Tokens.quicksettingsSliderModuleHeight

                ModuleTitle {
                    text: qsTr("Sound")
                }

                Row {
                    x: root.pad
                    y: parent.height - height - Tokens.spacingXs
                    width: parent.width - 2 * root.pad
                    spacing: Tokens.spacingSm
                    height: Tokens.controlSliderHeight

                    NavItem {
                        id: mute
                        anchors.verticalCenter: parent.verticalCenter
                        width: Tokens.menuIconSize + Tokens.spacingXs
                        height: width
                        accessibleName: Audio.muted ? qsTr("Unmute") : qsTr("Mute")
                        onActivated: Audio.toggleMute()

                        Icon {
                            anchors.centerIn: parent
                            size: Tokens.menuIconSize
                            name: Audio.iconName
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.ArrowCursor
                            onClicked: {
                                mute.forceActiveFocus();
                                Audio.toggleMute();
                            }
                        }
                    }

                    Slider {
                        id: volumeSlider
                        trackHeight: Tokens.controlSliderTrackCompact
                        verticalKeys: false
                        width: parent.width - mute.width - soundChevron.width - 2 * parent.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        accessibleName: qsTr("Output volume")
                        value: Audio.volume
                        onMoved: v => {
                            if (!Audio.setVolume(v))
                                volumeSlider.reset();
                        }
                    }

                    NavItem {
                        id: soundChevron
                        anchors.verticalCenter: parent.verticalCenter
                        width: Tokens.menuIconSize + Tokens.spacingXs
                        height: width
                        accessibleName: qsTr("Sound devices")
                        Accessible.checkable: true
                        Accessible.checked: root.expanded === "sound"
                        onActivated: root.toggleSection("sound")
                        handlesArrow: true
                        onArrow: direction => {
                            if (direction > 0)
                                root.open("sound");
                            else
                                soundChevron.navigate(-1, 0);
                        }

                        Icon {
                            anchors.centerIn: parent
                            size: Tokens.panelCcChevron
                            name: "chevron-right"
                            color: Appearance.colors.textSecondary
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.ArrowCursor
                            onClicked: {
                                soundChevron.forceActiveFocus();
                                root.toggleSection("sound");
                            }
                        }
                    }
                }
            }

            Module {
                id: appearanceBottom
                visible: Media.available
                cols: 4

                RadioRow {
                    id: appearanceBottomRow
                    width: parent.width
                    height: parent.height
                    inset: root.diskInset
                    iconName: Appearance.dark ? "moon" : "sun"
                    title: qsTr("Appearance")
                    subtitle: Model.appearanceLabel(Settings.appearance, {light: qsTr("Light"), dark: qsTr("Dark"), auto: qsTr("Auto")})
                    on: root.expanded === "appearance"
                    expandable: true
                    expanded: root.expanded === "appearance"
                    onToggled: root.toggleSection("appearance")
                    onExpandToggled: root.toggleSection("appearance")
                }
            }
        }
    }

    // The opened module: Wi-Fi and Bluetooth lists, sound devices, Appearance and Material.
    Module {
        id: detail
        visible: root.expanded !== ""
        cols: 4
        rows: 0
        radius: Tokens.quicksettingsRadiusDetail
        contentHeight: detailColumn.implicitHeight + 2 * root.pad

        Column {
            id: detailColumn
            x: root.pad
            y: root.pad
            width: parent.width - 2 * root.pad
            spacing: Tokens.spacingSm

            Item {
                width: parent.width
                height: Tokens.quicksettingsBackSize

                NavItem {
                    id: back
                    width: Tokens.quicksettingsBackSize
                    height: width
                    ringRadius: width / 2
                    accessibleName: qsTr("Back")
                    onActivated: root.collapse()
                    handlesArrow: true
                    onArrow: direction => {
                        if (direction < 0)
                            root.collapse();
                    }

                    Icon {
                        anchors.centerIn: parent
                        size: Tokens.panelCcChevron
                        name: "chevron-right"
                        rotation: 180
                        color: Appearance.colors.textSecondary
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.ArrowCursor
                        onClicked: root.collapse()
                    }
                }

                Label {
                    anchors.left: back.right
                    anchors.leftMargin: Tokens.spacingSm
                    anchors.right: headerToggle.left
                    anchors.rightMargin: Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.titleOf(root.expanded)
                    font.pixelSize: Tokens.typographyTitleSize
                    font.weight: Tokens.typographyMenuBoldWeight
                }

                Toggle {
                    id: headerToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.expanded === "wifi" || root.expanded === "bluetooth"
                    checked: root.expanded === "wifi" ? Connectivity.wifiEnabled : BluetoothState.enabled
                    accessibleName: root.expanded === "wifi" ? qsTr("Wi-Fi") : qsTr("Bluetooth")
                    onToggled: value => {
                        if (root.expanded === "wifi")
                            Connectivity.toggleWifi(value);
                        else
                            BluetoothState.setEnabled(value);
                    }
                }
            }

            WifiList {
                visible: root.expanded === "wifi"
            }

            BluetoothList {
                visible: root.expanded === "bluetooth"
            }

            SoundList {
                visible: root.expanded === "sound"
            }

            AppearanceSection {
                visible: root.expanded === "appearance"
            }
        }
    }

    // Dev guard note: a floating capsule under the modules.
    Module {
        id: note
        visible: root.devNote
        y: root.bodyHeight + root.gap
        cols: 4
        rows: 0
        contentHeight: Tokens.quicksettingsNoteHeight

        Caption {
            anchors.centerIn: parent
            elide: Text.ElideNone
            text: root.noteText
        }
    }
}
