pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The view switcher of a Files toolbar: the four views in one capsule, folded into one pop-up button while the toolbar has no
// room for it (the browser window's and the Open and Save panels', FilePanel.qml).
Item {
    id: root

    // The BrowserTab it switches (null: nothing to switch).
    required property var tab
    // The folded form: the current view's glyph and chevrons; it opens View As.
    property bool compact: false
    // The window's menu layer (View As of the folded form).
    required property var menuLayer
    // The views in toolbar order (Nav.viewModes), with the switcher's names.
    readonly property var viewModes: [
        {mode: "icons", name: qsTr("as Icons")},
        {mode: "list", name: qsTr("as List")},
        {mode: "columns", name: qsTr("as Columns")},
        {mode: "gallery", name: qsTr("as Gallery")}
    ]
    // The unfolded switcher's width (the window decides when to fold by it).
    readonly property real fullWidth: root.viewModes.length * Tokens.filesViewSegmentWidth + 2 * Tokens.filesViewGroupPadding

    width: root.compact ? Tokens.filesViewPopupWidth : root.fullWidth
    height: Tokens.toolbarCapsule

    // View switcher (macOS 27 Finder, measured on Finder-Home): four segments in a capsule, the selected view a pill
    // darker than the capsule, a rule between two views that are not selected.
    Rectangle {
        visible: !root.compact
        width: root.viewModes.length * Tokens.filesViewSegmentWidth + 2 * Tokens.filesViewGroupPadding
        height: Tokens.toolbarCapsule
        radius: height / 2
        color: Appearance.buttonFill
        Accessible.role: Accessible.Grouping
        Accessible.name: qsTr("View")

        Row {
            x: Tokens.filesViewGroupPadding
            height: parent.height

            Repeater {
                model: root.viewModes
                delegate: Item {
                    id: segment
                    required property var modelData
                    required property int index
                    readonly property bool current: root.tab !== null && root.tab.viewMode === segment.modelData.mode
                    width: Tokens.filesViewSegmentWidth
                    height: parent.height

                    ToolButton {
                        anchors.centerIn: parent
                        width: Tokens.filesViewPillWidth
                        height: Tokens.filesViewPillHeight
                        capsule: true
                        checkedColor: Appearance.withAlpha(Appearance.colors.fill, Tokens.filesViewPillOpacity)
                        checkable: true
                        radio: true
                        checked: segment.current
                        accessibleName: segment.modelData.name
                        onClicked: root.tab.setViewMode(segment.modelData.mode)

                        ViewGlyph {
                            anchors.centerIn: parent
                            kind: segment.modelData.mode
                        }
                    }

                    // The rule before this segment, where neither view beside it is the selected one.
                    Rectangle {
                        visible: segment.index > 0 && root.tab !== null && !segment.current && root.tab.viewMode !== root.viewModes[segment.index - 1].mode
                        x: -width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: Tokens.appsBorderWidth
                        height: Tokens.filesViewSeparatorHeight
                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.filesViewSeparatorOpacity)
                    }
                }
            }
        }
    }

    // The switcher folded into one pop-up button while the search field is open or the title has no room
    // (Finder-Search): the current view's glyph and up and down chevrons; it opens View As.
    Rectangle {
        visible: root.compact
        width: Tokens.filesViewPopupWidth
        height: Tokens.toolbarCapsule
        radius: height / 2
        color: Appearance.buttonFill

        ToolButton {
            id: viewPopup
            anchors.fill: parent
            capsule: true
            buttonSize: Tokens.toolbarCapsule
            enabled: root.tab !== null
            accessibleName: qsTr("View")
            onClicked: {
                const p = viewPopup.mapToItem(null, 0, viewPopup.height + Tokens.spacingXs);
                root.menuLayer.open(root.tab.viewSubmenu().submenu, p.x, p.y, id => root.tab.runAction(id, root.tab.activeFolder), root.tab.view, false);
            }

            Item {
                width: viewPopup.width
                height: viewPopup.height

                // In the slot of the icon glyph (15 wide); the wider glyphs keep its centre.
                ViewGlyph {
                    x: Tokens.filesViewPopupInset
                    anchors.verticalCenter: parent.verticalCenter
                    size: 2 * Tokens.filesViewIconsSquare + Tokens.filesViewIconsGap
                    kind: root.tab !== null ? root.tab.viewMode : "icons"
                    color: viewPopup.foreground
                }

                Repeater {
                    model: [-1, 1]

                    Icon {
                        required property int modelData
                        x: Tokens.filesViewPopupInset + 2 * Tokens.filesViewIconsSquare + Tokens.filesViewIconsGap + Tokens.filesViewPopupChevronGap
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.verticalCenterOffset: modelData * Tokens.filesViewPopupChevronOffset
                        name: "chevron-down"
                        rotation: modelData < 0 ? 180 : 0
                        size: Tokens.filesViewPopupChevronSize
                        color: viewPopup.foreground
                    }
                }
            }
        }
    }
}
