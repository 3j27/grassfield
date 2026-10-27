import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// One card of a cards block (spec SR4, macOS 27 Discover: 430 x 230, radius 14, on the group fill; the eyebrow in grey
// capitals, a title of up to three lines, a grey line of text, and a round artwork 15 pt from the right edge). The artwork
// is Grassfield's own: the app's icon on a light wash of its tint.
FocusScope {
    id: root

    required property var item
    readonly property var app: root.item.app
    readonly property color tint: root.item.tint !== "" && root.item.tint !== undefined ? root.item.tint : Appearance.colors.accent

    signal opened(string id)

    Accessible.role: Accessible.Button
    Accessible.name: [root.item.title, root.app.name, Store.sourceLabel(root.app.kind, root.app.repo), root.item.text].filter(t => t && t !== "").join(", ")
    Accessible.onPressAction: root.opened(root.app.id)

    Rectangle {
        anchors.fill: parent
        radius: Tokens.storeCardRadius
        color: Appearance.colors.groupFill
    }

    Text {
        id: eyebrow
        x: Tokens.storeCardTextInset
        y: Tokens.storeCardEyebrowBaseline - baselineOffset
        width: art.x - x - Tokens.storeCardTextGap
        textFormat: Text.PlainText
        text: root.item.eyebrow
        elide: Text.ElideRight
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeCardEyebrowSize
        font.weight: Tokens.storeEyebrowWeight
        font.capitalization: Font.AllUppercase
        font.letterSpacing: Appearance.tracking(Tokens.storeCardEyebrowSize)
    }

    Text {
        id: title
        x: Tokens.storeCardTextInset
        y: Tokens.storeCardTitleBaseline - baselineOffset
        width: art.x - x - Tokens.storeCardTextGap
        textFormat: Text.PlainText
        text: root.item.title
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.storeCardTitleLineHeight
        color: Appearance.colors.text
        font.family: Appearance.fontFamilyFor(Tokens.storeCardTitleSize)
        font.pixelSize: Tokens.storeCardTitleSize
        font.weight: Tokens.storeCardTitleWeight
        font.letterSpacing: Appearance.trackingFor(Tokens.storeCardTitleSize)
    }

    Text {
        x: Tokens.storeCardTextInset
        y: title.y + title.baselineOffset + (title.lineCount - 1) * Tokens.storeCardTitleLineHeight + Tokens.storeCardTextGapBelowTitle - baselineOffset
        width: art.x - x - Tokens.storeCardTextGap
        textFormat: Text.PlainText
        text: root.item.text
        elide: Text.ElideRight
        maximumLineCount: 1
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeCardBodySize
        font.letterSpacing: Appearance.tracking(Tokens.storeCardBodySize)
    }

    Rectangle {
        id: art
        width: Tokens.storeCardArtwork
        height: width
        radius: width / 2
        x: root.width - width - Tokens.storeCardArtworkInset
        anchors.verticalCenter: parent.verticalCenter
        color: Qt.tint(Appearance.colors.windowBackground, Appearance.withAlpha(root.tint, Tokens.storeCardArtworkWash))

        AppIcon {
            anchors.centerIn: parent
            size: Tokens.storeCardIconSize
            source: root.app.icon || ""
        }
    }

    TapHandler {
        onTapped: root.opened(root.app.id)
    }
}
