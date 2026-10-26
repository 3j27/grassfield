import QtQuick
import Grassfield.Ui

// The pop-up of a settings row that names a colour (macOS 27 Appearance: Text highlight color, Folder color): a dot in the
// chosen colour just before the pop-up's value, then the inline pop-up. model: [{id, text, color}]; value: the chosen id.
Item {
    id: root

    property var model: []
    property string value: ""
    property string accessibleName: ""

    signal picked(string id)

    readonly property var current: root.model.find(m => m.id === root.value) ?? null

    implicitWidth: Tokens.settingsColorDotSize + Tokens.settingsColorDotGap + combo.implicitWidth
    implicitHeight: combo.implicitHeight

    TextMetrics {
        id: valueMetrics
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
        text: root.current ? root.current.text : ""
    }

    Rectangle {
        x: combo.x + combo.width - (Tokens.settingsPopupIndicatorGap + Tokens.settingsPopupIndicatorSize + Tokens.settingsPopupInset)
            - Math.ceil(valueMetrics.advanceWidth) - Tokens.settingsColorDotGap - width
        anchors.verticalCenter: parent.verticalCenter
        width: Tokens.settingsColorDotSize
        height: width
        radius: width / 2
        visible: root.current !== null
        color: root.current ? root.current.color : "transparent"
        border.width: Tokens.appsBorderWidth
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    ComboBox {
        id: combo
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        inline: true
        accessibleName: root.accessibleName
        model: root.model.map(m => ({id: m.id, text: m.text}))
        value: root.value
        onPicked: id => root.picked(id)
    }
}
