pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services

// "About This Wallpaper": the attribution of the online daily picture (Title, Author, Source, Licence, Last updated), on the
// frosted material, opened from the desktop menu. Everything shown comes from the helper's sanitized sidecar and is drawn as
// plain text (never rich text, never a link that opens by itself). Return, Space, Esc and the button close it.
FocusScope {
    id: root

    // {title, author, credit, caption, licenseShort, licenseUrl, sourceUrl, fetchedAt}
    readonly property var entry: WallpaperState.online.entry || ({})

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

    // The source page without its scheme ("commons.wikimedia.org/wiki/File:..."): shown as text, never opened from here.
    readonly property string sourceText: (root.entry.sourceUrl || "").replace(/^https?:\/\//, "")

    readonly property var rows: [
        {label: qsTr("Author"), value: root.entry.author || root.entry.credit || ""},
        {label: qsTr("Source"), value: root.sourceText !== "" ? qsTr("Wikimedia Commons") + "\n" + root.sourceText : qsTr("Wikimedia Commons")},
        {label: qsTr("Licence"), value: root.entry.licenseShort || ""},
        {label: qsTr("Last updated"), value: root.updated}
    ].filter(r => r.value !== "")

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.closeRequested();
            event.accepted = true;
        }
    }

    Material {
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
                Accessible.name: row.modelData.label + ": " + row.modelData.value

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: row.modelData.label
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }

                Text {
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
