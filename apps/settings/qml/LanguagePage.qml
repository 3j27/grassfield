pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "General.js" as General

// General > Language & Region (the structure of the macOS 15 capture, docs/audits/settings-parity-2026-10-26.md § Language
// & Region). The language is Omarchy's (owner decision 2026-10-26): `omarchy-language list` and `omarchy-language` read it,
// `omarchy-language <code>` changes it for the next login (it generates the locale through Omarchy's own grant or pkexec).
// Only in a real session and only when it is installed (Omarchy 4.0.4 has none): otherwise the row shows the session's
// language, and the group says that changing it needs a newer Omarchy (General.languageNote).
// The formats are Grassfield's keys (region.formats, region.firstDayOfWeek): the shell formats its dates, times and numbers
// with them at once (Translator.formats). Not built (docs/specs/settings.md): more than one preferred language, calendars
// other than the Gregorian one, temperature and measurement units (nothing in Grassfield shows one), per-app languages.
SettingsPage {
    id: root

    required property var backend
    required property var system
    required property var store

    title: qsTr("Language & Region")

    property var languages: []
    property bool listAnswered: false
    property string language: ""
    readonly property bool installed: root.backend.omarchyLanguage === true
    readonly property string note: General.languageNote(root.installed, root.system.dev, root.listAnswered, root.languages.length)
    // The session's language (its LANG: the locale Settings itself runs in).
    readonly property string sessionLanguage: General.languageName(Qt.locale().nativeLanguageName, Qt.locale().name)
    // The language sent to omarchy-language until it answered, then the one to log in again for. Whether it still runs is the
    // Backend's (a visit while it runs shows it and cannot start a second one).
    property string pending: ""
    readonly property bool waiting: (root.backend.pendingActions ?? {})["language.act"] !== undefined
    property string changed: ""
    property real now: Date.now()

    readonly property var regions: root.backend ? root.backend.regionLocales() : []
    readonly property string formats: root.store.value("region.formats")
    // The formats the shell uses (General.formatsLocale, the Translator's rule): the language in the chosen region, else the
    // language's own (Settings itself runs in the language's).
    readonly property var formatsLocale: General.formatsLocale(Qt.locale().name, root.formats)
    // A fixed sample, as the macOS previews: 19 August of this year, 1 234 567.89.
    readonly property date sample: new Date(new Date(root.now).getFullYear(), 7, 19)

    function nameOf(code: string): string {
        for (const l of root.languages) {
            if (l.code === code)
                return l.name;
        }
        return code;
    }

    function setLanguage(code: string): void {
        if (code === root.language)
            return;
        root.changed = "";
        if (root.system.act("language", General.languageArgv(code), "language.act"))
            root.pending = code;
    }

    // Choosing the language's own region stores "auto" (the formats then follow a later language change).
    function setRegion(name: string): void {
        root.store.set("region.formats", name === Qt.locale().name ? "auto" : name);
    }

    Component.onCompleted: {
        if (!root.installed || root.system.dev)
            return;
        root.system.query(["omarchy-language", "list"], "language.list");
        root.system.query(["omarchy-language"], "language.current");
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "language.list") {
                root.languages = ok ? General.parseLanguages(output) : [];
                root.listAnswered = true;
            } else if (tag === "language.current") {
                root.language = ok ? General.currentLanguage(output) : "";
            } else if (tag === "language.act") {
                if (ok)
                    root.changed = root.pending;
                root.pending = "";
                root.system.query(["omarchy-language"], "language.current");
            }
        }
    }

    // The preview's time runs.
    Timer {
        interval: 1000
        repeat: true
        running: root.visible
        onTriggered: root.now = Date.now()
    }

    SettingsGroup {
        caption: qsTr("Preferred Languages")
        footnote: root.note === "tool" ? qsTr("Changing the language needs a newer version of Omarchy.")
            : root.note === "list" ? qsTr("Omarchy did not give its list of languages.")
            : root.system.errors["language.act"] !== undefined ? qsTr("The language could not be changed: %1.").arg(root.system.errors["language.act"])
            : root.changed !== "" ? qsTr("Log out and back in to use %1 everywhere.").arg(root.nameOf(root.changed)) : ""

        SettingsRow {
            title: qsTr("Primary language")
            subtitle: root.waiting ? qsTr("Changing the language…") : ""
            valueText: root.languages.length === 0 ? root.sessionLanguage : ""

            ComboBox {
                visible: root.languages.length > 0
                inline: true
                enabled: !root.waiting
                accessibleName: qsTr("Primary language")
                // The native name, and the English one beside it (findable whatever the current language).
                model: root.languages.map(l => ({id: l.code, text: l.name === l.english ? l.name : qsTr("%1 — %2").arg(l.name).arg(l.english)}))
                value: root.waiting && root.pending !== "" ? root.pending : root.language
                onPicked: id => root.setLanguage(id)
            }
        }
    }

    SettingsGroup {
        // The formats as they read now (macOS: the long date and time, then the short one, an amount and a number).
        Item {
            width: parent.width
            height: Tokens.settingsPreviewRowHeight
            Accessible.role: Accessible.StaticText
            Accessible.name: first.text + ". " + second.text

            Text {
                id: first
                textFormat: Text.PlainText
                y: Tokens.settingsPreviewFirstBaseline - baselineOffset
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: qsTr("%1 at %2").arg(root.formatsLocale.toString(new Date(root.now), root.formatsLocale.dateFormat(Locale.LongFormat)))
                    .arg(root.formatsLocale.toString(new Date(root.now), root.formatsLocale.timeFormat(Locale.LongFormat)))
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
            Row {
                id: second
                readonly property string text: [root.formatsLocale.toString(new Date(root.now), root.formatsLocale.dateTimeFormat(Locale.ShortFormat)),
                    Number(12345.67).toLocaleCurrencyString(root.formatsLocale), root.formatsLocale.toString(4567.89, "f", 2)].join(", ")
                x: Math.round((parent.width - width) / 2)
                y: Tokens.settingsPreviewFirstBaseline + Tokens.settingsPreviewLineGap - shortDate.baselineOffset
                spacing: Tokens.settingsPreviewItemGap

                Text {
                    id: shortDate
                    textFormat: Text.PlainText
                    text: root.formatsLocale.toString(new Date(root.now), root.formatsLocale.dateTimeFormat(Locale.ShortFormat))
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
                Text {
                    textFormat: Text.PlainText
                    text: Number(12345.67).toLocaleCurrencyString(root.formatsLocale)
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
                Text {
                    textFormat: Text.PlainText
                    text: root.formatsLocale.toString(4567.89, "f", 2)
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }
        }

        SettingsRow {
            title: qsTr("Region")
            ComboBox {
                inline: true
                accessibleName: qsTr("Region")
                model: root.regions.map(r => ({id: r.name, text: r.territory}))
                value: root.formats !== "auto" ? root.formats : Qt.locale().name
                onPicked: id => root.setRegion(id)
            }
        }
        SettingsRow {
            title: qsTr("First day of week")
            ComboBox {
                inline: true
                accessibleName: qsTr("First day of week")
                model: [{id: "auto", text: qsTr("Automatic (%1)").arg(root.formatsLocale.dayName(root.formatsLocale.firstDayOfWeek, Locale.LongFormat))}]
                    .concat(["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].map((d, i) => ({id: d, text: Qt.locale().dayName(i, Locale.LongFormat)})))
                value: root.store.value("region.firstDayOfWeek")
                onPicked: id => root.store.set("region.firstDayOfWeek", id)
            }
        }
        SettingsRow {
            title: qsTr("Date format")
            valueText: root.formatsLocale.toString(root.sample, root.formatsLocale.dateFormat(Locale.ShortFormat))
        }
        SettingsRow {
            title: qsTr("Number format")
            valueText: root.formatsLocale.toString(1234567.89, "f", 2)
        }
    }

    DevNote {
        system: root.system
    }
}
