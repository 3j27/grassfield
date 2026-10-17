pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.notifications
import qs.services
import qs.overlay.controlcenter

// Control Center (spec controlcenter.md): connectivity tile (Wi-Fi, Bluetooth, airplane mode), Focus,
// Now Playing, Display and Sound sliders, keyboard backlight, and the Appearance section.
// One section is expanded at a time (`expanded`). Values come live from the services.
FocusScope {
    id: root

    // "", "wifi", "bluetooth", "sound" or "appearance".
    property string expanded: ""
    // Shown while a GRASSFIELD_DEV session suppresses a change to the owner's machine.
    property bool devNote: false

    readonly property real gap: Tokens.spacingSm
    readonly property real innerWidth: width - 2 * Tokens.spacingMd

    function toggleSection(id: string): void {
        expanded = expanded === id ? "" : id;
    }

    function showDevNote(): void {
        devNote = true;
        noteTimer.restart();
    }

    width: Tokens.panelControlCenterWidth
    height: column.implicitHeight + 2 * Tokens.spacingMd
    Accessible.role: Accessible.Window
    Accessible.name: qsTr("Control Center")

    Keys.onEscapePressed: Popups.close()

    // Scanning only while the list is on screen.
    readonly property bool scanWanted: expanded === "wifi" && Connectivity.wifiEnabled
    onScanWantedChanged: Connectivity.setScanning(scanWanted)

    Component.onDestruction: {
        Connectivity.setScanning(false);
        Audio.devRestore();
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

    Material {
        anchors.fill: parent
        radius: Tokens.radiusPanel
    }

    Column {
        id: column
        x: Tokens.spacingMd
        y: Tokens.spacingMd
        width: root.innerWidth
        spacing: Tokens.spacingSm

        Item {
            width: parent.width
            height: title.implicitHeight

            Label {
                id: title
                width: parent.width - note.width - Tokens.spacingSm
                text: qsTr("Control Center")
                font.pixelSize: Tokens.typographyTitleSize
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Caption {
                id: note
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.devNote
                elide: Text.ElideNone
                text: qsTr("dev: not applied")
            }
        }

        // Top grid: connectivity on the left; Focus and Now Playing on the right.
        Item {
            width: parent.width
            height: Tokens.panelCcGridHeight

            Tile {
                id: connectivity
                width: (parent.width - root.gap) * Tokens.panelCcLeftFraction
                height: parent.height
                padding: Tokens.spacingSm + Tokens.spacingXs

                Column {
                    width: parent.width
                    spacing: (connectivity.height - 2 * connectivity.padding - 3 * Tokens.panelCcIconButton) / 2

                    RadioRow {
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

                    RadioRow {
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

                    RadioRow {
                        iconName: "airplane"
                        title: qsTr("Airplane Mode")
                        subtitle: Connectivity.airplane ? qsTr("Wi-Fi and Bluetooth off") : qsTr("Off")
                        on: Connectivity.airplane
                        available: Connectivity.airplaneAvailable
                        onToggled: Connectivity.setAirplane(!Connectivity.airplane)
                    }
                }
            }

            Tile {
                id: focus
                x: connectivity.width + root.gap
                width: parent.width - x
                height: Media.available ? parent.height - nowPlaying.height - root.gap : parent.height
                padding: Tokens.spacingSm + Tokens.spacingXs

                RadioRow {
                    iconName: "moon"
                    title: qsTr("Focus")
                    subtitle: Notifications.dnd ? qsTr("Do Not Disturb") : qsTr("Off")
                    on: Notifications.dnd
                    onToggled: Notifications.setDnd(!Notifications.dnd)
                }
            }

            NowPlaying {
                id: nowPlaying
                visible: Media.available
                x: connectivity.width + root.gap
                y: parent.height - height
                width: parent.width - x
            }
        }

        Tile {
            visible: root.expanded === "wifi"
            Caption {
                text: qsTr("Wi-Fi")
            }

            WifiList {}
        }

        Tile {
            visible: root.expanded === "bluetooth"
            Caption {
                text: qsTr("Bluetooth")
            }

            BluetoothList {}
        }

        Tile {
            visible: Brightness.available

            Caption {
                text: qsTr("Display")
            }

            Row {
                width: parent.width
                spacing: Tokens.spacingSm
                height: Tokens.controlSliderHeight

                Icon {
                    id: displayIcon
                    anchors.verticalCenter: parent.verticalCenter
                    size: Tokens.menuIconSize
                    name: "display"
                }

                Slider {
                    width: parent.width - displayIcon.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Display brightness")
                    value: Brightness.level
                    onMoved: v => {
                        if (!Brightness.setLevel(v) && Brightness.devSession)
                            root.showDevNote();
                    }
                }
            }
        }

        Tile {
            Caption {
                text: qsTr("Sound")
            }

            Row {
                width: parent.width
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
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            mute.forceActiveFocus();
                            Audio.toggleMute();
                        }
                    }
                }

                Slider {
                    width: parent.width - mute.width - soundChevron.width - 2 * parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Output volume")
                    value: Audio.volume
                    onMoved: v => Audio.setVolume(v)
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
                    onArrow: direction => {
                        if ((direction > 0) !== (root.expanded === "sound"))
                            root.toggleSection("sound");
                    }

                    Icon {
                        anchors.centerIn: parent
                        size: Tokens.panelCcChevron
                        name: root.expanded === "sound" ? "chevron-down" : "chevron-right"
                        color: Appearance.colors.textSecondary
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            soundChevron.forceActiveFocus();
                            root.toggleSection("sound");
                        }
                    }
                }
            }

            SoundList {
                visible: root.expanded === "sound"
            }
        }

        Tile {
            visible: Brightness.kbdAvailable

            Caption {
                text: qsTr("Keyboard Brightness")
            }

            Row {
                width: parent.width
                spacing: Tokens.spacingSm
                height: Tokens.controlSliderHeight

                Icon {
                    id: kbdIcon
                    anchors.verticalCenter: parent.verticalCenter
                    size: Tokens.menuIconSize
                    name: "keyboard"
                }

                Slider {
                    width: parent.width - kbdIcon.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Keyboard brightness")
                    value: Brightness.kbdLevel
                    onMoved: v => {
                        if (!Brightness.setKbdLevel(v) && Brightness.devSession)
                            root.showDevNote();
                    }
                }
            }
        }

        Tile {
            RadioRow {
                iconName: Appearance.dark ? "moon" : "sun"
                title: qsTr("Appearance")
                subtitle: Settings.appearance === "light" ? qsTr("Light") : qsTr("Dark")
                on: root.expanded === "appearance"
                expandable: true
                expanded: root.expanded === "appearance"
                onToggled: root.toggleSection("appearance")
                onExpandToggled: root.toggleSection("appearance")
            }

            AppearanceSection {
                visible: root.expanded === "appearance"
            }
        }
    }
}
