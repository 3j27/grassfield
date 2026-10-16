pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui

// Banner stack, top-right under the menu bar, on the first screen only. The window exists
// per screen but is mapped only while a banner is shown; input and blur follow the banners.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool primary: Quickshell.screens.length > 0 && modelData.name === Quickshell.screens[0].name
        readonly property int pad: Tokens.spacingLg

        function itemFor(key: string): var {
            for (let i = 0; i < stack.count; i++) {
                const item = stack.itemAt(i) as Banner;
                if (item && item.key === key)
                    return item;
            }
            return null;
        }

        screen: modelData
        visible: primary && Notifications.banners.length > 0
        anchors {
            top: true
            right: true
        }
        // No layer-shell margins: the offset under the menu bar lives inside the transparent window.
        implicitWidth: Tokens.notificationBannerWidth + 2 * win.pad
        implicitHeight: column.y + column.height + win.pad
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-banners"
        // qmllint disable missing-type
        mask: Region {
            item: column
        }
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.visible ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            regions: blurRegions.instances
        }

        Variants {
            id: blurRegions
            model: Notifications.banners.slice(0, Tokens.notificationBannerMaxVisible)

            Region {
                id: region
                required property var modelData
                item: {
                    stack.count;
                    const banner = win.itemFor(region.modelData.key);
                    return banner ? banner.cardItem : null;
                }
                radius: Tokens.radiusBanner
            }
        }

        Column {
            id: column
            x: win.pad
            y: Tokens.menubarHeight + Tokens.notificationBannerGap
            width: Tokens.notificationBannerWidth
            spacing: Tokens.notificationBannerGap

            Repeater {
                id: stack
                model: Notifications.banners.slice(0, Tokens.notificationBannerMaxVisible)

                delegate: Banner {
                    required property var modelData
                    key: modelData.key
                }
            }
        }
    }
}
