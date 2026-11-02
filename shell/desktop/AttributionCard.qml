pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services

// "About This Wallpaper": the attribution of the online daily picture, or of a shipped photograph (ADR-0040 step 2c; the
// host passes it as `entry`): Title, Author (a photograph's Credit: the author's own attribution line with its copyright
// notice), Source, Licence, Changes (a photograph: Grassfield resized it) and Last updated (the online picture only), on the
// frosted material, opened from the desktop menu. Everything shown comes from the helper's sanitized sidecar and is drawn as
// plain text (never rich text). The licence name links to the licence and the file page to its source (CC BY 4.0 section
// 3(a)(1)(C)): a link opens only on a click or Return, only an https address (WallpaperConfig.linkOf), as an argument vector
// through Apps.openDetached. Return, Space, Esc and the button close the card (a focused link opens instead).
FocusScope {
    id: root

    // {title, author, credit, caption, licenseShort, licenseUrl, sourceUrl, fetchedAt, modified}; a photograph's
    // (WallpaperConfig.photoAbout) has its credit line and `modified` instead of an author, a caption and fetchedAt.
    property var entry: WallpaperState.online.entry || ({})

    signal closeRequested

    width: Tokens.wallpaperAboutWidth
    height: content.implicitHeight + 2 * Tokens.spacingLg
    activeFocusOnTab: true
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("About This Wallpaper")

    readonly property string updated: {
        const d = new Date(root.entry.fetchedAt || "");
        return isNaN(d.getTime()) ? "" : Qt.locale().toString(d, Locale.ShortFormat);
    }

    // The file page as it reads ("commons.wikimedia.org/wiki/File:Name.jpg": no scheme, percent-escapes decoded) and the
    // addresses the two links may open ("" when the address is not a clean https one: the text is then not a link).
    readonly property string sourceText: WallpaperConfig.displayUrl(root.entry.sourceUrl)
    readonly property string sourceLink: WallpaperConfig.linkOf(root.entry.sourceUrl)
    readonly property string licenceLink: WallpaperConfig.linkOf(root.entry.licenseUrl)

    readonly property string authorLabel: qsTr("Author")
    readonly property string creditLabel: qsTr("Credit")
    readonly property string sourceLabel: qsTr("Source")
    readonly property string licenceLabel: qsTr("Licence")
    readonly property string changesLabel: qsTr("Changes")
    readonly property string updatedLabel: qsTr("Last updated")
    // What Grassfield did to a shipped photograph (THIRD_PARTY.md, "Wallpaper photographs"): the licence's "indicate if You
    // modified the Licensed Material".
    readonly property string changesText: qsTr("Resized and re-encoded by Grassfield, metadata removed")
    // Both sources are Wikimedia Commons: the online picture of the day, and every shipped photograph (its source page is a
    // Commons file page, tests/ci/wallpaper_photos.py).
    readonly property string commonsName: qsTr("Wikimedia Commons")

    // {label, value (plain), linkText + url (a link)}.
    readonly property var rows: [
        {label: root.entry.author ? root.authorLabel : root.creditLabel, value: root.entry.author || root.entry.credit || "", linkText: "", url: ""},
        root.sourceLink !== "" ? {label: root.sourceLabel, value: root.commonsName, linkText: root.sourceText, url: root.sourceLink} : {label: root.sourceLabel, value: root.sourceText !== "" ? root.commonsName + "\n" + root.sourceText : root.commonsName, linkText: "", url: ""},
        root.licenceLink !== "" && (root.entry.licenseShort || "") !== "" ? {label: root.licenceLabel, value: "", linkText: root.entry.licenseShort, url: root.licenceLink} : {label: root.licenceLabel, value: root.entry.licenseShort || "", linkText: "", url: ""},
        {label: root.changesLabel, value: root.entry.modified === true ? root.changesText : "", linkText: "", url: ""},
        {label: root.updatedLabel, value: root.updated, linkText: "", url: ""}
    ].filter(r => r.value !== "" || r.linkText !== "")

    function openLink(url: string): void {
        if (WallpaperConfig.linkOf(url) === "")
            return;
        Apps.openDetached(["xdg-open", url]);
        root.closeRequested();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.closeRequested();
            event.accepted = true;
        }
    }

    // A text surface: the menus' class (ADR-0039 step 22).
    Material {
        glassClass: "menu"
        anchors.fill: parent
        radius: Tokens.radiusMenu
    }

    Column {
        id: content
        x: Tokens.spacingLg
        y: Tokens.spacingLg
        width: root.width - 2 * Tokens.spacingLg
        spacing: Tokens.spacingSm

        Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.entry.title || qsTr("Picture of the Day")
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            visible: (root.entry.caption || "") !== ""
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
            text: root.entry.caption || ""
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Repeater {
            model: root.rows

            delegate: Column {
                id: row

                required property var modelData

                width: content.width
                spacing: 0
                Accessible.role: Accessible.StaticText
                Accessible.name: row.modelData.label + ": " + (row.modelData.value !== "" ? row.modelData.value + " " : "") + row.modelData.linkText

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: row.modelData.label
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                Text {
                    visible: row.modelData.value !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    text: row.modelData.value
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                LinkText {
                    visible: row.modelData.url !== ""
                    width: parent.width
                    text: row.modelData.linkText
                    target: row.modelData.url
                    onActivated: root.openLink(row.modelData.url)
                }
            }
        }

        Item {
            width: parent.width
            height: closeButton.height

            Button {
                id: closeButton
                anchors.right: parent.right
                primary: true
                text: qsTr("Close")
                focus: true
                onClicked: root.closeRequested()
            }
        }
    }
}
