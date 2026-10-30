pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "General.js" as General

// About This Computer (ADR-0040 ID-19): a small window of fixed size that `grassfield-settings --about` opens (the shell's
// Grassfield menu starts it; one Settings per user, src/settingsinstance.h, so one About window and one Settings window,
// in the same process). Computer first, as macOS 27's About This Mac:
// Grassfield's drawing of the computer (DevicePicture, by hostname1's chassis) and its model name; processor, memory and
// graphics (AboutFacts, the lines of Settings > General > About); the product line with the Grassfield mark in the brand
// green (the default accent's green, whatever accent is chosen; IQ-B1 B); More Info…, which brings the one Settings window
// to General > About; "Built for Omarchy · based on Arch Linux" (master-prompt §14). Nothing waits on the GUI
// thread (hostname1 and lspci answer asynchronously); the window maps once both have answered, at the latest after
// settings.aboutWindowRevealTimeout with what it has, a late line then filling in (P-2, P-6), and says so once in the log (P-8).
Window {
    id: root

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The running Settings (src/settingsinstance.h): More Info… asks it for the Settings window at General > About.
    required property var instance
    // ADR-0015: the titlebar-only style of Get Info; the compositor plugin draws no titlebar on it, and the shell finds this
    // window by its role to bring it forward (shell/services/SettingsApp.qml openAbout).
    property string gfChromeRole: "info"
    // hostname1's answer (General.parseHost), null until it came or when it failed; `hostDone` once it came.
    property var host: null
    property bool hostDone: false
    // hostname1 and lspci have both answered.
    readonly property bool answered: root.hostDone && root.facts.graphicsDone
    // They answered, or the wait ran out: the window maps.
    property bool ready: false

    readonly property AboutFacts facts: AboutFacts {
        backend: root.backend
    }
    readonly property color brandGreen: Appearance.dark ? Tokens.colorDark.accent : Tokens.colorLight.accent
    readonly property int fixedHeight: Math.ceil(toolbar.height + content.implicitHeight + Tokens.spacingLg)

    function reveal(how: string): void {
        if (root.ready)
            return;
        root.ready = true;
        console.info("grassfield-settings: About This Computer shown (" + how + ")");
    }

    title: qsTr("About This Computer")
    width: Tokens.settingsAboutWindowWidth
    height: root.fixedHeight
    minimumWidth: Tokens.settingsAboutWindowWidth
    maximumWidth: Tokens.settingsAboutWindowWidth
    minimumHeight: root.fixedHeight
    maximumHeight: root.fixedHeight
    visible: root.ready
    color: Appearance.colors.windowBackground

    Component.onCompleted: root.backend.busQuery("host.state", "about.host")

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag !== "about.host")
                return;
            root.host = ok ? General.parseHost(output) : null;
            root.hostDone = true;
        }
    }

    onAnsweredChanged: {
        if (root.answered)
            root.reveal((root.host ? "hostname1" : "no hostname1") + " and " + (root.facts.graphics !== "" ? "lspci" : "no lspci") + " answered");
    }

    Timer {
        interval: Tokens.settingsAboutWindowRevealTimeout
        running: !root.ready
        onTriggered: root.reveal("the wait ran out: " + (root.hostDone ? "" : "hostname1 ") + (root.facts.graphicsDone ? "" : "lspci ") + "still to answer")
    }

    ConfigStore {
        id: cfg
        backend: root.backend
    }

    SettingsAppearance {
        backend: root.backend
        config: cfg
    }

    Shortcut {
        sequences: ["Ctrl+W", "Esc"]
        enabled: root.active
        onActivated: root.close()
    }

    // A label and its value, the label right-aligned in the left column (About This Mac's two columns); `mark` puts the
    // Grassfield mark before the value.
    component FactRow: Item {
        id: fact

        property string label: ""
        property string value: ""
        property bool mark: false

        width: content.width
        height: Math.max(labelText.implicitHeight, valueText.implicitHeight)
        visible: fact.value !== ""
        Accessible.role: Accessible.StaticText
        Accessible.name: qsTr("%1: %2").arg(fact.label).arg(fact.value)

        Text {
            id: labelText
            width: Math.round(fact.width * Tokens.settingsAboutWindowLabelColumn)
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            textFormat: Text.PlainText
            text: fact.label
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            Accessible.ignored: true
        }

        Icon {
            id: markIcon
            visible: fact.mark
            x: labelText.width + Tokens.spacingSm
            y: Math.round((labelText.implicitHeight - height) / 2)
            name: "grassfield-logo"
            size: Tokens.settingsAboutWindowMarkSize
            color: root.brandGreen
        }

        Text {
            id: valueText
            x: labelText.width + Tokens.spacingSm + (fact.mark ? markIcon.width + Tokens.spacingXs : 0)
            width: fact.width - x
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: fact.value
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            Accessible.ignored: true
        }
    }

    // No title on the bar (About This Mac shows none); a window of fixed size: no zoom, no minimize, a double-click does
    // nothing.
    UnifiedToolbar {
        id: toolbar
        width: parent.width
        window: root
        style: "titlebar"
        title: root.title
        showTitle: false
        canMinimize: false
        doubleClickAction: "none"
    }

    Binding {
        target: toolbar.controls
        property: "canZoom"
        value: false
    }

    Column {
        id: content

        anchors.top: toolbar.bottom
        x: Tokens.spacingLg
        width: parent.width - 2 * Tokens.spacingLg
        topPadding: Tokens.settingsAboutWindowPictureTop
        spacing: Tokens.spacingXs

        DevicePicture {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.settingsAboutWindowPictureWidth
            height: Tokens.settingsAboutWindowPictureHeight
            kind: General.deviceKind(root.host ? root.host.chassis : "")
        }

        Item {
            width: 1
            height: Tokens.spacingSm
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: General.modelName(root.host) || qsTr("Computer")
            color: Appearance.colors.text
            font.family: Appearance.fontFamilyFor(Tokens.settingsAboutWindowNameSize)
            font.pixelSize: Tokens.settingsAboutWindowNameSize
            font.weight: Tokens.typographyMenuBoldWeight
            font.letterSpacing: Appearance.trackingFor(Tokens.settingsAboutWindowNameSize)
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Item {
            width: 1
            height: Tokens.spacingMd
        }

        FactRow {
            label: qsTr("Processor")
            value: root.facts.processor
        }
        FactRow {
            label: qsTr("Memory")
            value: root.facts.memory
        }
        FactRow {
            label: qsTr("Graphics")
            value: root.facts.graphics
        }
        FactRow {
            label: qsTr("Software")
            value: qsTr("Grassfield Desktop %1").arg(root.backend.appVersion)
            mark: true
        }

        Item {
            width: 1
            height: Tokens.spacingMd
        }

        Button {
            anchors.horizontalCenter: parent.horizontalCenter
            push: true
            text: qsTr("More Info…")
            onClicked: root.instance.openSettings("about")
        }

        Item {
            width: 1
            height: Tokens.spacingMd
        }

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: qsTr("Built for Omarchy · based on Arch Linux")
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }
    }
}
