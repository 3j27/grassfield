pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Window

// A capsule of an app window's chrome (macOS 27; Settings, the Store, Files, Preview): the toolbar's back / forward group,
// view group and search capsule, and the sidebar's search field. No outline in the standard appearance (macOS 27 draws
// none, measured on ss-004-005: ADR-0024 amendment 2026-11-03):
//  - a capsule is a white fill lifted by a soft shadow (toolbar.shadow*), the shape cut out of the shadow so it never
//    shows through the translucent fill;
//  - a field (`field: true`, the sidebar search) is a flat tinted fill with no shadow.
// Increase Contrast draws the control outline of every shared control. It is not glass: no blur is requested or faked.
Rectangle {
    id: root

    // A field is the sidebar's flat tinted search field (no shadow); everything else, toolbar search fields included, is a
    // lifted white capsule. The fill opacity follows it (the dark appearance takes the matching *Dark token).
    property bool field: false
    property real fillOpacity: root.field ? Tokens.toolbarFieldFillOpacity : Tokens.toolbarCapsuleFillOpacity
    readonly property real hairline: 1 / Math.max(1, Screen.devicePixelRatio)
    readonly property real fillAlpha: root.field ? (Appearance.dark ? Tokens.toolbarFieldFillOpacityDark : root.fillOpacity)
        : (Appearance.dark ? Tokens.toolbarCapsuleFillOpacityDark : root.fillOpacity)
    // The shadow needs this much room round the shape.
    readonly property int shadowMargin: Tokens.toolbarShadowBlur + Tokens.toolbarShadowOffsetY

    radius: height / 2
    // A field tints the window with the text colour; a capsule is white (the knob colour) in both appearances.
    color: Appearance.withAlpha(root.field ? Appearance.colors.text : Appearance.colors.knob, root.fillAlpha)
    border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
    border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

    Item {
        id: shadowSource
        visible: false
        layer.enabled: !root.field
        x: -root.shadowMargin
        y: -root.shadowMargin
        width: root.width + 2 * root.shadowMargin
        height: root.height + 2 * root.shadowMargin

        RectangularShadow {
            x: root.shadowMargin
            y: root.shadowMargin
            width: root.width
            height: root.height
            radius: root.radius
            blur: Tokens.toolbarShadowBlur
            offset: Qt.vector2d(0, Tokens.toolbarShadowOffsetY)
            color: Appearance.withAlpha(Appearance.colors.shadow, Appearance.dark ? Tokens.toolbarShadowOpacityDark : Tokens.toolbarShadowOpacity)
        }
    }

    Item {
        id: shadowCutout
        visible: false
        layer.enabled: !root.field
        x: shadowSource.x
        y: shadowSource.y
        width: shadowSource.width
        height: shadowSource.height

        Rectangle {
            x: root.shadowMargin
            y: root.shadowMargin
            width: root.width
            height: root.height
            radius: root.radius
            color: "black"
        }
    }

    MultiEffect {
        visible: !root.field
        z: -1
        x: shadowSource.x
        y: shadowSource.y
        width: shadowSource.width
        height: shadowSource.height
        source: shadowSource
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: shadowCutout
        maskInverted: true
    }
}
