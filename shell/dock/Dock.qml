pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Grassfield.Ui
import qs.platform
import qs.services

// Bottom dock, one per screen: pinned apps (Settings) followed by running apps that are not
// pinned. Click launches (desktop entry) or focuses (platform). Magnification and autohide
// are not implemented yet.
Scope {
    id: root

    // [{key, name, icon, entry, toplevels, pinned}], rebuilt when apps/toplevels/pins change.
    property var items: []

    function lookup(id: string): var {
        if (id === "")
            return null;
        const byId = DesktopEntries.byId(id);
        return byId ? byId : DesktopEntries.heuristicLookup(id);
    }

    function rebuild(): void {
        const list = [];
        const byKey = {};
        const pins = Settings.dockPinned ? Settings.dockPinned : [];
        for (let i = 0; i < pins.length; i++) {
            const entry = lookup(pins[i]);
            if (!entry || byKey[entry.id] !== undefined)
                continue;
            byKey[entry.id] = list.length;
            list.push({
                key: entry.id,
                name: entry.name,
                icon: entry.icon,
                entry: entry,
                toplevels: [],
                pinned: true
            });
        }
        const tops = Compositor.toplevels ? Compositor.toplevels.values : [];
        for (let j = 0; j < tops.length; j++) {
            const top = tops[j];
            if (top.appId === "")
                continue;
            const entry = lookup(top.appId);
            const key = entry ? entry.id : top.appId;
            if (byKey[key] === undefined) {
                byKey[key] = list.length;
                list.push({
                    key: key,
                    name: entry ? entry.name : top.appId,
                    icon: entry ? entry.icon : top.appId,
                    entry: entry,
                    toplevels: [],
                    pinned: false
                });
            }
            list[byKey[key]].toplevels.push(top);
        }
        items = list;
    }

    function activateItem(item: var): void {
        if (item.toplevels.length > 0)
            Compositor.activate(item.toplevels[0]);
        else if (item.entry)
            item.entry.execute();
    }

    Component.onCompleted: rebuild()

    Connections {
        target: Compositor.toplevels

        function onValuesChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: Settings

        function onDockPinnedChanged(): void {
            root.rebuild();
        }
    }

    Variants {
        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            readonly property int dockWidth: 2 * Tokens.dockPadding + Math.max(0, root.items.length) * Tokens.dockIconSize
                + Math.max(0, root.items.length - 1) * Tokens.dockSpacing
            readonly property int dockHeight: Tokens.dockIconSize + 2 * Tokens.dockPadding + Tokens.dockIndicatorSize + Tokens.dockSpacing

            screen: modelData
            anchors.bottom: true
            implicitWidth: dockWidth + 2 * material.shadowMargin
            implicitHeight: dockHeight + material.shadowMargin + Tokens.dockBottomMargin
            exclusiveZone: dockHeight + Tokens.dockBottomMargin
            color: "transparent"
            focusable: false
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "grassfield-dock"
            // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
            // qmllint disable missing-type
            BackgroundEffect.blurRegion: material.blurActive ? blurRegion : null
            // qmllint enable missing-type

            Region {
                id: blurRegion
                item: material
                radius: material.radius
            }

            Material {
                id: material
                x: material.shadowMargin
                y: material.shadowMargin
                width: win.dockWidth
                height: win.dockHeight
                radius: Tokens.radiusDock

                Row {
                    x: Tokens.dockPadding
                    y: Tokens.dockPadding
                    spacing: Tokens.dockSpacing

                    Repeater {
                        model: root.items

                        delegate: Item {
                            id: tile

                            required property var modelData

                            readonly property bool running: modelData.toplevels.length > 0

                            width: Tokens.dockIconSize
                            height: Tokens.dockIconSize + Tokens.dockIndicatorSize + Tokens.dockSpacing
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: running ? qsTr("%1, running").arg(modelData.name) : modelData.name
                            Accessible.focusable: true
                            Accessible.onPressAction: root.activateItem(modelData)
                            Keys.onReturnPressed: root.activateItem(modelData)
                            Keys.onEnterPressed: root.activateItem(modelData)
                            Keys.onSpacePressed: root.activateItem(modelData)

                            Rectangle {
                                width: Tokens.dockIconSize
                                height: Tokens.dockIconSize
                                radius: Tokens.radiusDockIcon
                                color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
                                opacity: hover.hovered || tile.activeFocus ? 1 : 0
                                border.width: tile.activeFocus ? 2 : 0
                                border.color: Appearance.colors.accent

                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: Appearance.duration(Tokens.motionFast)
                                        easing.type: Easing.BezierSpline
                                        easing.bezierCurve: Appearance.curve
                                    }
                                }
                            }

                            IconImage {
                                width: Tokens.dockIconSize
                                height: Tokens.dockIconSize
                                source: Quickshell.iconPath(tile.modelData.icon, "application-x-executable")
                            }

                            Rectangle {
                                visible: tile.running
                                width: Tokens.dockIndicatorSize
                                height: Tokens.dockIndicatorSize
                                radius: width / 2
                                color: Appearance.colors.indicator
                                x: (tile.width - width) / 2
                                y: Tokens.dockIconSize + Tokens.dockSpacing
                            }

                            HoverHandler {
                                id: hover
                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                onTapped: {
                                    tile.forceActiveFocus();
                                    root.activateItem(tile.modelData);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
