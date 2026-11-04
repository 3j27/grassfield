pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.osd
import qs.services
import qs.platform

// Banner stack, top-right under the menu bar, on ONE screen: the focused one (first screen
// when unknown). A single window and a single Repeater, so there is exactly one set of
// banner delegates (hover state and expiry belong to the one visible banner). The window is
// mapped only while a banner exists; delegates exist only for the banners that are shown
// (the rest of the queue is just model rows). While the OSD pill is visible the stack sits
// below it, so the two never overlap.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: win

    // The banners show on the main display (macOS: notifications appear on the display that holds the menu bar and Dock, ADR-0044).
    readonly property string targetName: MainDisplay.screenName !== "" ? MainDisplay.screenName : Compositor.activeScreenName
    readonly property var targetScreen: {
        for (const s of Quickshell.screens) {
            if (s.name === targetName)
                return s;
        }
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    readonly property int pad: Tokens.spacingLg
    // Space taken by the OSD pill (plus its gap) while it is on this screen.
    readonly property real osdOffset: Osd.shown && targetScreen !== null && targetScreen.name === Compositor.activeScreenName ? Tokens.osdHeight + Tokens.osdGap : 0

    function itemFor(index: int): var {
        const loader = stack.itemAt(index) as Loader;
        return loader ? (loader.item as Banner) : null;
    }

    screen: targetScreen
    // The Notifications column and Quick Settings replace the banners while they are open (their modules float over the
    // same area, and a banner would show through the gaps between them).
    visible: targetScreen !== null && Notifications.bannerCount > 0 && !Notifications.centerOpen && Popups.kind !== "controlcenter"
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
        model: Array.from({length: Math.min(Notifications.bannerCount, Tokens.notificationBannerMaxVisible)}, (_, i) => i)

        Region {
            id: region
            required property int modelData
            item: {
                stack.count;
                const banner = win.itemFor(region.modelData);
                return banner ? banner.cardItem : null;
            }
            radius: Tokens.radiusBanner
        }
    }

    Column {
        id: column
        x: win.pad
        // macOS: banners start where the Notifications column starts.
        y: Tokens.menubarHeight + Tokens.notificationCenterInset + win.osdOffset
        width: Tokens.notificationBannerWidth
        spacing: Tokens.notificationBannerGap

        // The banners make room for the OSD; under Reduce Motion they jump (ADR-0039 step 5).
        Behavior on y {
            enabled: !Appearance.reduceMotion
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionNormal)
                // A move: the move curve (ADR-0039 step 20).
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        Repeater {
            id: stack
            model: Notifications.bannerModel

            delegate: Loader {
                id: slot

                required property int index
                required property string key
                required property int nid
                required property string appName
                required property string appIcon
                required property string image
                required property string summary
                required property string bodyHtml
                required property real time
                required property int urgency
                required property string actionsJson

                // Queued banners (beyond the visible count) have no delegate at all.
                active: index < Tokens.notificationBannerMaxVisible
                visible: active

                sourceComponent: Banner {
                    // The stack's area on the output (the window is anchored top-right): the backdrop of the glass (G-3).
                    backdropRect: Qt.rect(win.targetScreen ? win.targetScreen.width - win.pad - Tokens.notificationBannerWidth : 0, column.y, Tokens.notificationBannerWidth, column.height)
                    key: slot.key
                    nid: slot.nid
                    appName: slot.appName
                    appIcon: slot.appIcon
                    image: slot.image
                    summary: slot.summary
                    bodyHtml: slot.bodyHtml
                    time: slot.time
                    urgency: slot.urgency
                    actionsJson: slot.actionsJson
                }
            }
        }
    }
}
