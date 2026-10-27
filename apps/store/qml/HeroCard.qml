import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// One card of the hero carousel (spec SR4, macOS 27 Discover: 880 x 340 at the reference width, radius 12, the eyebrow in
// capitals, a title of two lines and one line of text in white). The artwork is Grassfield's own (ADR-0037 e.10): the
// app's icon large on a tint taken from it, darkened until white text on it holds A2 (StoreView::heroTint), lighter
// towards the icon; an app whose icon gives no colour gets the neutral tint.
FocusScope {
    id: root

    required property var item
    readonly property var app: root.item.app
    readonly property color tint: root.item.tint !== "" && root.item.tint !== undefined ? root.item.tint : Tokens.storeHeroFallbackTint

    signal opened(string id)

    Accessible.role: Accessible.Button
    Accessible.name: [root.item.title, root.app.name, Store.sourceLabel(root.app.kind, root.app.repo), root.item.text].filter(t => t && t !== "").join(", ")
    Accessible.onPressAction: root.opened(root.app.id)

    Rectangle {
        id: art
        anchors.fill: parent
        radius: Tokens.storeHeroRadius
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
                position: 0
                color: root.tint
            }
            GradientStop {
                position: Tokens.storeHeroGradientStart
                color: root.tint
            }
            GradientStop {
                position: 1
                color: Qt.lighter(root.tint, Tokens.storeHeroGradientLift)
            }
        }
    }

    AppIcon {
        x: Math.round(root.width * Tokens.storeHeroIconCentre - width / 2)
        anchors.verticalCenter: parent.verticalCenter
        size: Tokens.storeHeroIconSize
        source: root.app.icon || ""
    }

    Text {
        id: eyebrow
        x: Tokens.storeHeroTextInset
        y: Tokens.storeHeroEyebrowBaseline - baselineOffset
        width: Tokens.storeHeroTextWidth
        textFormat: Text.PlainText
        text: root.item.eyebrow
        elide: Text.ElideRight
        color: Appearance.withAlpha(Tokens.storeHeroText, Tokens.storeHeroSecondaryOpacity)
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeHeroEyebrowSize
        font.weight: Tokens.storeEyebrowWeight
        font.capitalization: Font.AllUppercase
        font.letterSpacing: Appearance.tracking(Tokens.storeHeroEyebrowSize)
    }

    Text {
        id: title
        x: Tokens.storeHeroTextInset
        y: Tokens.storeHeroTitleBaseline - baselineOffset
        width: Tokens.storeHeroTextWidth
        textFormat: Text.PlainText
        text: root.item.title
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.storeHeroTitleLineHeight
        color: Tokens.storeHeroText
        font.family: Appearance.fontFamilyFor(Tokens.storeHeroTitleSize)
        font.pixelSize: Tokens.storeHeroTitleSize
        font.weight: Tokens.storeHeroTitleWeight
        font.letterSpacing: Appearance.trackingFor(Tokens.storeHeroTitleSize)
    }

    Text {
        x: Tokens.storeHeroTextInset
        // Under the title's last line, whether it has one line or two.
        y: title.y + title.baselineOffset + (title.lineCount - 1) * Tokens.storeHeroTitleLineHeight + Tokens.storeHeroTextGap - baselineOffset
        width: Tokens.storeHeroTextWidth
        textFormat: Text.PlainText
        text: root.item.text
        elide: Text.ElideRight
        maximumLineCount: 1
        color: Appearance.withAlpha(Tokens.storeHeroText, Tokens.storeHeroSecondaryOpacity)
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeHeroBodySize
        font.letterSpacing: Appearance.tracking(Tokens.storeHeroBodySize)
    }

    TapHandler {
        onTapped: root.opened(root.app.id)
    }
}
