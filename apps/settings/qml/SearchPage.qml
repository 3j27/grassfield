pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Settings > Search as macOS 27 lays out its Spotlight pane (docs/audits/settings-parity-2026-10-26.md § Search): the header
// card, Search History with Delete Search History… (historyDeleteRequested: Main asks first, then writes
// search.historyResetAt), Search Results: the kinds of results Search shows, each with its switch (search.show*), and the
// clipboard history (ADR-0034 step 3, docs/specs/clipboard.md CB-13): Results from Clipboard, how long the history is
// available, Keep clipboard history after logging out, and Clear Clipboard History… (clipboardClearRequested: Main asks, then
// writes search.clipboard.clearedAt, and pinnedClearedAt too when the pinned items go). The shell follows the keys live
// (shell/search/Search.qml, shell/services/Clipboard.qml).
SettingsPage {
    id: root

    required property var store

    readonly property bool clipboardOn: root.store.value("search.clipboard.enabled") === true

    signal historyDeleteRequested
    signal clipboardClearRequested

    // Clear Clipboard History… once confirmed (Main's sheet): one write; the shell deletes the items not pinned, and with
    // alsoPinned the pinned ones too.
    function clearClipboard(alsoPinned: bool): void {
        const now = Date.now();
        const entries = {
            "search.clipboard.clearedAt": now
        };
        if (alsoPinned)
            entries["search.clipboard.pinnedClearedAt"] = now;
        root.store.setMany(entries);
    }

    title: qsTr("Search")

    // One kind of result: its tile, its name and its switch.
    component ResultRow: Item {
        id: result

        property string key: ""
        property string title: ""
        property string glyph: ""
        property string tileColor: "graphite"

        // The separator above (the header's for the first row) takes the row's first point; macOS centres the row's
        // content in the 42 points under it, so the next row's separator overlaps this row's last point.
        readonly property real middle: 1 + height / 2

        width: parent ? parent.width : 0
        height: Tokens.settingsResultRowHeight
        Accessible.role: Accessible.Grouping
        Accessible.name: result.title

        // The separator above the row starts at the name, as macOS draws it.
        Rectangle {
            visible: result.Positioner.index > 1
            x: Tokens.settingsResultTitleX
            width: parent.width - x - Tokens.settingsRowInset
            height: Tokens.appsBorderWidth
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        Rectangle {
            x: Tokens.settingsResultIconX
            y: result.middle - height / 2
            width: Tokens.settingsResultIconSize
            height: width
            radius: Math.round(width * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
            gradient: TileGradient {
                name: result.tileColor
            }

            Icon {
                anchors.centerIn: parent
                name: result.glyph
                size: Math.round(Tokens.settingsResultIconSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
                color: Tokens.settingsSidebarTileGlyph
            }
        }

        Text {
            x: Tokens.settingsResultTitleX
            y: result.middle - height / 2
            width: toggle.x - x - Tokens.spacingLg
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: result.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Toggle {
            id: toggle
            anchors.right: parent.right
            anchors.rightMargin: Tokens.settingsRowInset
            y: result.middle - height / 2
            accessibleName: qsTr("Show %1 in Search").arg(result.title)
            checked: root.store.value(result.key) === true
            onToggled: c => root.store.set(result.key, c)
        }
    }

    PaneBanner {
        icon: "search"
        tileColor: "blue"
        title: qsTr("Search")
        text: qsTr("Search finds apps, documents, settings and answers on this computer, and runs system commands. What you type never leaves this computer.")
    }

    SettingsGroup {
        SettingsRow {
            implicitHeight: Tokens.settingsPushRowHeight
            title: qsTr("Search History")
            Button {
                push: true
                text: qsTr("Delete Search History…")
                onClicked: root.historyDeleteRequested()
            }
        }
    }

    SettingsGroup {
        // The header: what the switches are for, above a separator across the whole group.
        Item {
            width: parent.width
            // The separator under it lies on the first row's first point.
            height: Tokens.settingsResultsHeaderHeight
            Accessible.role: Accessible.Grouping
            Accessible.name: qsTr("Search Results")

            Text {
                x: Tokens.settingsRowInset
                y: Tokens.settingsBannerTitleBaseline - baselineOffset
                textFormat: Text.PlainText
                text: qsTr("Search Results")
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Text {
                x: Tokens.settingsRowInset
                y: Tokens.settingsBannerTextBaseline - baselineOffset
                width: parent.width - 2 * Tokens.settingsRowInset
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: qsTr("Allows these results to appear in Search.")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.settingsCaptionDetailSize
            }

            Rectangle {
                y: Tokens.settingsResultsHeaderHeight
                width: parent.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }
        }

        ResultRow {
            key: "search.showApps"
            title: qsTr("Applications")
            glyph: "apps"
            tileColor: "blue"
        }

        ResultRow {
            key: "search.showCalculator"
            title: qsTr("Calculator")
            glyph: "calculator"
            tileColor: "graphite"
        }

        ResultRow {
            key: "search.showConversions"
            title: qsTr("Conversions")
            glyph: "convert"
            tileColor: "orange"
        }

        ResultRow {
            key: "search.showDocuments"
            title: qsTr("Documents")
            glyph: "document"
            tileColor: "blue"
        }

        ResultRow {
            key: "search.showRecents"
            title: qsTr("Recent Documents")
            glyph: "clock"
            tileColor: "purple"
        }

        ResultRow {
            key: "search.showSettings"
            title: qsTr("Settings")
            glyph: "gear"
            tileColor: "graphite"
        }

        ResultRow {
            key: "search.showCommands"
            title: qsTr("System Commands")
            glyph: "power"
            tileColor: "red"
        }
    }
    // macOS 26.0 shows its clipboard group last (W-39); macOS 27 names the switch "Results from Clipboard" and offers 30 minutes,
    // 8 hours or 7 days (M-9). The pinned items stay while the history is off, so Clear stays available.
    SettingsGroup {
        SettingsRow {
            title: qsTr("Results from Clipboard")
            subtitle: qsTr("Allows Search to find and show items you copied. Personal and sensitive information may appear in the results. Turning it off deletes the items you did not pin.")

            Toggle {
                accessibleName: qsTr("Results from Clipboard")
                checked: root.clipboardOn
                onToggled: c => root.store.set("search.clipboard.enabled", c)
            }
        }

        SettingsRow {
            title: qsTr("Clipboard history is available in Search for")

            ComboBox {
                inline: true
                enabled: root.clipboardOn
                accessibleName: qsTr("Clipboard history is available in Search for")
                model: [{id: "30m", text: qsTr("30 minutes")}, {id: "8h", text: qsTr("8 hours")}, {id: "7d", text: qsTr("7 days")}]
                value: String(root.store.value("search.clipboard.retention"))
                onPicked: id => root.store.set("search.clipboard.retention", id)
            }
        }

        SettingsRow {
            title: qsTr("Keep clipboard history after logging out")
            subtitle: qsTr("The items you did not pin are kept on this computer, readable only by you, until they are no longer available.")

            Toggle {
                enabled: root.clipboardOn
                accessibleName: qsTr("Keep clipboard history after logging out")
                checked: root.store.value("search.clipboard.keepOnDisk") === true
                onToggled: c => root.store.set("search.clipboard.keepOnDisk", c)
            }
        }

        SettingsRow {
            implicitHeight: Tokens.settingsPushRowHeight
            title: qsTr("Clipboard History")

            Button {
                push: true
                text: qsTr("Clear Clipboard History…")
                onClicked: root.clipboardClearRequested()
            }
        }
    }
}
