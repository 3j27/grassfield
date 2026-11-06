pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Path bar: the location as clickable segments (home or the root first). Segments accept drops. In a search location the
// bar shows the path of the selected result instead (Finder-Search); its last segment shows the item in its folder. Each
// segment is a Tab stop that Space or Return opens, with the shared ring on keyboard focus (ADR-0039 step 23).
Item {
    id: root
    // A rule or frame: one point (apps.borderWidth, ADR-0039 D5) in whole device pixels, 1 px at 1.25 where 1 pt drew a soft
    // 1.25 px (UI audit 2026-11-05 U37); 1 px at 1x and 2 px at 2x as before.
    readonly property real hairline: Math.max(1, Math.round(Tokens.appsBorderWidth * Screen.devicePixelRatio)) / Math.max(1, Screen.devicePixelRatio)

    property var tab: null
    // The selected search result's path (one item selected in a search location), else null.
    readonly property var resultSegments: {
        const t = root.tab;
        if (!t || !t.fileSearch || !t.activeFolder || t.activeFolder.selectedCount !== 1)
            return null;
        const urls = t.selection();
        return urls.length === 1 ? t.app.pathSegments(urls[0]) : null;
    }
    // A search with no result selected shows no path (Finder-Search).
    readonly property var shownSegments: root.resultSegments ?? (root.tab && !root.tab.fileSearch ? root.tab.segments : [])

    // A path wider than the bar shortens its middle segments first, the first and the last kept whole (macOS Finder; UI audit
    // 2026-11-05, LOW), none under files.pathSegmentMinWidth; what still does not fit scrolls as before. `naturals`: each
    // segment's whole width (with its chevron), from its label's own width, so that shortening never feeds back.
    property var naturals: []
    function setNatural(index: int, width: real): void {
        const next = root.naturals.slice(0, root.shownSegments.length);
        next[index] = width;
        root.naturals = next;
    }
    readonly property real natural: {
        let w = 0;
        for (let i = 0; i < root.shownSegments.length; i++)
            w += root.naturals[i] || 0;
        return w + Math.max(0, root.shownSegments.length - 1) * row.spacing;
    }
    readonly property real middleCap: {
        const n = root.shownSegments.length;
        if (n < 3 || root.natural <= flick.width)
            return Infinity;
        // Each middle segment keeps its chevron and the label's padding; the labels share the rest.
        const fixed = (root.naturals[0] || 0) + (root.naturals[n - 1] || 0) + (n - 2) * (Tokens.filesChevronSize + 3 * Tokens.spacingXs) + (n - 1) * row.spacing;
        return Math.max(Tokens.filesPathSegmentMinWidth, Math.floor((flick.width - fixed) / (n - 2)));
    }

    implicitHeight: Tokens.filesPathBarHeight
    Accessible.role: Accessible.ToolBar
    Accessible.name: qsTr("Path")

    Rectangle {
        width: parent.width
        height: root.hairline
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.leftMargin: Tokens.spacingSm
        anchors.rightMargin: Tokens.spacingSm
        contentWidth: row.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        // Keep the deepest segment visible.
        onContentWidthChanged: contentX = Math.max(0, contentWidth - width)

        Row {
            id: row
            height: flick.height
            spacing: Tokens.spacingXs

            Repeater {
                model: root.shownSegments

                delegate: Row {
                    id: segment
                    required property var modelData
                    required property int index
                    readonly property bool last: segment.index === root.shownSegments.length - 1
                    readonly property bool middle: segment.index > 0 && !segment.last
                    // Its whole width, chevron included (the bar's measure).
                    readonly property real natural: label.implicitWidth + 2 * Tokens.spacingXs + (segment.index > 0 ? Tokens.filesChevronSize + Tokens.spacingXs : 0)
                    onNaturalChanged: root.setNatural(segment.index, segment.natural)
                    Component.onCompleted: root.setNatural(segment.index, segment.natural)
                    // A search result's own segment: shown in its folder rather than opened as a location.
                    function activate(): void {
                        if (root.resultSegments && segment.last)
                            root.tab.showInEnclosingFolder();
                        else
                            root.tab.navigate(segment.modelData.url, true);
                    }

                    height: row.height
                    spacing: Tokens.spacingXs

                    Icon {
                        visible: segment.index > 0
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevron-right"
                        size: Tokens.filesChevronSize
                        color: Appearance.windowSecondary
                    }

                    Item {
                        id: segmentButton
                        width: label.width + 2 * Tokens.spacingXs
                        height: parent.height
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: DisplayName.text(segment.modelData.label)
                        Accessible.focusable: true
                        Accessible.onPressAction: segment.activate()
                        // A segment off the bar's visible part scrolls in with the focus.
                        onActiveFocusChanged: {
                            if (!segmentButton.activeFocus)
                                return;
                            const left = segmentButton.mapToItem(row, 0, 0).x;
                            let x = flick.contentX;
                            if (left < x)
                                x = left;
                            else if (left + segmentButton.width > x + flick.width)
                                x = left + segmentButton.width - flick.width;
                            flick.contentX = Math.max(0, Math.min(Math.max(0, flick.contentWidth - flick.width), x));
                        }
                        Keys.onPressed: event => {
                            if (ActivationKeys.activation(event.key)) {
                                segment.activate();
                                event.accepted = true;
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: Tokens.spacingXs
                            anchors.bottomMargin: Tokens.spacingXs
                            radius: Tokens.radiusControl
                            color: mouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                            border.width: drop.containsDrag ? Tokens.filesDropBorder : 0
                            border.color: Appearance.colors.accent

                            FocusRing {
                                visible: segmentFocus.active
                            }
                        }

                        KeyFocus {
                            id: segmentFocus
                        }

                        Text {
                            id: label
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            width: segment.middle ? Math.min(implicitWidth, root.middleCap) : implicitWidth
                            elide: Text.ElideRight
                            text: DisplayName.text(segment.modelData.label)
                            color: segment.last ? Appearance.colors.text : Appearance.windowSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                            font.weight: segment.last ? Tokens.typographyMenuWeight : Tokens.typographySmallWeight
                        }

                        DropArea {
                            id: drop
                            anchors.fill: parent
                            keys: ["text/uri-list"]
                            // Recents takes no drop (Finder).
                            onEntered: event => event.accepted = !root.tab.app.isRecents(segment.modelData.url)
                            onDropped: event => {
                                if (event.hasUrls) {
                                    root.tab.dropUrls(event.urls, segment.modelData.url, null);
                                    event.accept(Qt.CopyAction);
                                }
                            }
                        }

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: segment.activate()
                        }
                    }
                }
            }
        }
    }
}
