pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Grassfield.Ui
import "Store.js" as Store

// An app's page (spec SR9-SR12): its icon, name, summary and developer, the button, the source and the licence, always;
// the screenshots (when AppStream has them and they are on, owner ST6: fetched when the page opens); the description;
// What's New (AppStream's releases, else the package's version and build date); and the Information list.
ScrollPage {
    id: root

    required property var backend
    property var app: ({})
    // pacman -Si's facts, asked for when the page opens (version, sizes, build date).
    property var facts: ({})
    readonly property string factsPackage: root.app.package ? root.app.package : (root.app.packages && root.app.packages.length > 0 ? root.app.packages[0] : "")

    signal linkRequested(string url)
    signal uninstallRequested(var app)
    signal detailsRequested(string id)
    signal tryAgainRequested(var app, string kind)

    // What the buttons may do (StoreBackend::actions), the app's operation and how its last one ended (spec SR13, SR19, SR22).
    readonly property var actions: root.app.id ? (root.backend.revision, root.backend.actions(root.app.id)) : ({})
    readonly property bool busy: (root.backend.operations || []).some(o => o.app === root.app.id)
    readonly property var result: root.app.id ? (root.backend.results || {})[root.app.id] : undefined

    title: ""
    headerHeight: Tokens.storeProductTop
    Accessible.role: Accessible.Pane
    Accessible.name: root.app.name || ""

    Component.onCompleted: {
        if (root.factsPackage !== "" && (root.app.kind === "repo" || root.app.kind === "setup"))
            root.backend.requestPackageInfo(root.factsPackage);
    }

    Connections {
        target: root.backend
        function onPackageInfo(name: string, facts: var): void {
            if (name === root.factsPackage)
                root.facts = facts;
        }
    }

    // Header: icon, texts, the button, source and licence.
    Item {
        width: root.contentWidth
        implicitHeight: Math.max(icon.height, texts.implicitHeight)

        AppIcon {
            id: icon
            size: Tokens.storeProductIconSize
            source: root.app.icon || ""
        }

        Column {
            id: texts
            anchors.left: icon.right
            anchors.leftMargin: Tokens.storeProductHeaderGap
            anchors.right: parent.right
            spacing: Tokens.storeProductLineGap

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.app.name || ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamilyFor(Tokens.storeProductNameSize)
                font.pixelSize: Tokens.storeProductNameSize
                font.weight: Tokens.typographyMenuBoldWeight
                font.letterSpacing: Appearance.trackingFor(Tokens.storeProductNameSize)
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: root.app.summary || ""
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeProductSummarySize
                font.letterSpacing: Appearance.tracking(Tokens.storeProductSummarySize)
            }

            Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: root.app.developer || ""
                elide: Text.ElideRight
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
                font.letterSpacing: Appearance.tracking(Tokens.storeBadgeSize)
            }

            Item {
                width: 1
                height: Tokens.storeProductButtonGap
            }

            Row {
                spacing: Tokens.storeProductButtonRowGap

                StoreButton {
                    anchors.verticalCenter: parent.verticalCenter
                    app: root.app
                    large: true
                }

                // "…": Uninstall… for an installed app (SR22), dimmed with the reason when the Store may not remove it.
                Item {
                    id: more
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.actions.installed === true
                    width: Tokens.storeButtonLargeHeight
                    height: Tokens.storeButtonLargeHeight
                    activeFocusOnTab: visible
                    Accessible.role: Accessible.ButtonMenu
                    Accessible.name: qsTr("More for %1").arg(root.app.name || "")
                    Accessible.onPressAction: more.openMenu()

                    function openMenu(): void {
                        moreMenu.items = [{id: "uninstall", text: qsTr("Uninstall…"), destructive: true,
                                           enabled: root.actions.uninstall === "" && !root.busy}];
                        moreMenu.focusBack = more;
                        moreMenu.openAt(0, more.height + Tokens.spacingXs);
                    }

                    Keys.onPressed: event => {
                        if (ActivationKeys.activation(event.key)) {
                            more.openMenu();
                            event.accepted = true;
                        }
                    }

                    Icon {
                        anchors.centerIn: parent
                        name: "ellipsis-circle"
                        size: Tokens.storeButtonLargeHeight
                        color: Appearance.windowSecondary
                    }

                    FocusRing {
                        shapeRadius: more.width / 2
                        visible: more.activeFocus
                    }

                    TapHandler {
                        onTapped: more.openMenu()
                    }

                    MenuPopup {
                        id: moreMenu
                        accessibleName: more.Accessible.name
                        onChosen: id => {
                            if (id === "uninstall")
                                root.uninstallRequested(root.app);
                        }
                    }
                }

                SourceBadge {
                    anchors.verticalCenter: parent.verticalCenter
                    kind: root.app.kind || ""
                    repo: root.app.repo || ""
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.app.license ? qsTr("Licence: %1").arg(root.app.license) : qsTr("Licence not stated")
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.storeBadgeSize
                    font.letterSpacing: Appearance.tracking(Tokens.storeBadgeSize)
                }
            }

            // How its last operation ended (SR19), with Try Again and Details….
            Row {
                visible: !!root.result && Store.resultText(root.result) !== ""
                width: parent.width
                spacing: Tokens.storeProductButtonRowGap
                topPadding: Tokens.storeResultGap

                Text {
                    width: Math.min(implicitWidth, parent.width - links.width - parent.spacing)
                    textFormat: Text.PlainText
                    text: Store.resultText(root.result)
                    wrapMode: Text.Wrap
                    color: Appearance.colors.danger
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.storeBadgeSize
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }

                Row {
                    id: links
                    spacing: Tokens.storeProductButtonRowGap

                    LinkText {
                        visible: Store.canTryAgain(root.result)
                        text: qsTr("Try Again")
                        onActivated: root.tryAgainRequested(root.app, root.result.kind)
                    }

                    LinkText {
                        text: qsTr("Details…")
                        onActivated: root.detailsRequested(root.app.id)
                    }
                }
            }

            // Why the Store does not offer to uninstall it (SR22: part of Omarchy, of Grassfield, of the system, …).
            Text {
                width: parent.width
                visible: root.actions.installed === true && text !== ""
                textFormat: Text.PlainText
                text: Store.uninstallReasonText(root.actions.uninstall || "")
                wrapMode: Text.Wrap
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
            }

            Text {
                width: parent.width
                visible: root.app.installed !== undefined && !root.app.launcher && root.app.kind === "repo"
                textFormat: Text.PlainText
                text: qsTr("This app has no window of its own: it runs in a terminal.")
                wrapMode: Text.Wrap
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeBadgeSize
            }
        }
    }

    // Screenshots (SR10): a gallery with arrows; third-party images, loaded only while they are on and the Store is online.
    Item {
        id: gallery
        width: root.contentWidth
        visible: (root.app.screenshots || []).length > 0
        implicitHeight: visible ? Tokens.storeScreenshotHeight : 0


        ListView {
            id: shots
            width: parent.width + Tokens.storeContentMargin
            height: parent.height
            orientation: ListView.Horizontal
            spacing: Tokens.storeScreenshotGap
            model: root.app.screenshots || []
            boundsBehavior: Flickable.StopAtBounds
            clip: false
            keyNavigationEnabled: false

            delegate: Item {
                id: shot
                required property string modelData
                required property int index
                readonly property string caption: (root.app.captions || [])[index] || ""
                // Read again when the Store goes offline or comes back (the provider refuses offline anyway).
                readonly property string source: root.backend.online ? root.backend.screenshotSource(modelData) : ""
                height: shots.height
                width: picture.status === Image.Ready && picture.implicitHeight > 0
                    ? Math.min(shots.width, Math.round(picture.implicitWidth * height / picture.implicitHeight))
                    : Math.round(height * Tokens.storeScreenshotPlaceholderRatio)
                Accessible.role: Accessible.Graphic
                Accessible.name: caption !== "" ? caption
                    : qsTr("Screenshot %1 of %2 of %3").arg(index + 1).arg(shots.count).arg(root.app.name)

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.storeScreenshotRadius
                    color: Appearance.colors.groupFill
                    visible: picture.status !== Image.Ready

                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 2 * Tokens.spacingLg
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: !root.backend.sources.screenshots ? qsTr("Screenshots are turned off.")
                            : !root.backend.online ? qsTr("Screenshots are not loaded while you're offline.")
                            : picture.status === Image.Error ? qsTr("This screenshot could not be loaded.") : ""
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.storeBadgeSize
                    }
                }

                Image {
                    id: picture
                    anchors.fill: parent
                    source: shot.source
                    sourceSize.height: shots.height * 2
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    visible: status === Image.Ready
                    smooth: true
                }
            }
        }

        HoverHandler {
            id: galleryHover
        }

        CarouselArrow {
            x: Tokens.storeCarouselArrowInset
            anchors.verticalCenter: parent.verticalCenter
            back: true
            shown: galleryHover.hovered && !shots.atXBeginning
            onClicked: shots.contentX = Math.max(shots.originX, shots.contentX - gallery.width + Tokens.storeScreenshotGap)
        }

        CarouselArrow {
            x: gallery.width - width - Tokens.storeCarouselArrowInset
            anchors.verticalCenter: parent.verticalCenter
            shown: galleryHover.hovered && !shots.atXEnd
            onClicked: shots.contentX = Math.min(shots.contentWidth - shots.width + shots.originX, shots.contentX + gallery.width - Tokens.storeScreenshotGap)
        }
    }

    // The description (plain text: paragraphs, and bullets as AppStream lists them).
    Text {
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        visible: text !== ""
        textFormat: Text.PlainText
        text: root.app.description || ""
        wrapMode: Text.Wrap
        lineHeight: Tokens.storeBodyLineHeight
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.storeBodySize
        font.letterSpacing: Appearance.tracking(Tokens.storeBodySize)
    }

    // What's New: the newest release AppStream lists, else the package's version and build day.
    Column {
        id: whatsNew
        readonly property var release: (root.app.releases || []).length > 0 ? root.app.releases[0] : null
        readonly property string version: whatsNew.release ? whatsNew.release.version : (root.facts.version || "")
        readonly property string date: whatsNew.release ? whatsNew.release.date : (root.facts.buildDate || "")
        width: Math.min(root.contentWidth, Tokens.storeTextMaxWidth)
        visible: whatsNew.version !== ""
        spacing: Tokens.storeProductLineGap

        SectionHeading {
            text: qsTr("What's New")
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: whatsNew.date !== "" ? qsTr("Version %1 · %2").arg(whatsNew.version).arg(whatsNew.date) : qsTr("Version %1").arg(whatsNew.version)
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBadgeSize
        }

        Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: whatsNew.release ? whatsNew.release.notes : ""
            wrapMode: Text.Wrap
            lineHeight: Tokens.storeBodyLineHeight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeBodySize
        }
    }

    // Information (SR11).
    Column {
        width: root.contentWidth
        spacing: Tokens.storeProductLineGap

        SectionHeading {
            text: qsTr("Information")
        }

        Grid {
            id: info
            width: parent.width
            columns: Math.max(1, Math.floor((width + columnSpacing) / (Tokens.storeInfoMinWidth + columnSpacing)))
            columnSpacing: Tokens.storeInfoColumnGap
            rowSpacing: Tokens.storeInfoRowGap
            readonly property real cellWidth: (width - (columns - 1) * columnSpacing) / columns
            readonly property var setup: root.app.setup || ({})
            readonly property var facts: [
                {label: qsTr("Source"), value: Store.sourceLabel(root.app.kind, root.app.repo)},
                {label: qsTr("Developer"), value: root.app.developer || ""},
                {label: root.app.kind === "setup" ? qsTr("Packages") : qsTr("Package"),
                 value: root.app.kind === "setup" ? (root.app.packages || []).join(", ") : (root.app.package || "")},
                {label: qsTr("Version"), value: root.facts.version || ""},
                {label: qsTr("Download Size"), value: root.facts.downloadSize || ""},
                {label: qsTr("Installed Size"), value: root.facts.installedSize || ""},
                {label: qsTr("Category"), value: (root.app.categories || []).join(", ")},
                {label: qsTr("Languages"), value: Store.languagesText(root.app.languages)},
                {label: qsTr("Content Rating"), value: Store.ratingText(root.app.rated, root.app.rating)},
                {label: qsTr("Licence"), value: root.app.license || qsTr("Not stated")},
                {label: qsTr("What This Setup Changes"), value: info.setup.changes || ""},
                {label: qsTr("Setup"), value: info.setup.install || ""},
                {label: qsTr("Address"), value: root.app.webUrl || ""},
                {label: qsTr("Homepage"), value: Store.hostOf(root.app.homepage), link: root.app.homepage || ""},
                {label: qsTr("Bug Tracker"), value: Store.hostOf(root.app.bugtracker), link: root.app.bugtracker || ""}
            ].filter(f => f.value !== "")

            Repeater {
                model: info.facts

                delegate: InfoItem {
                    required property var modelData
                    width: info.cellWidth
                    label: modelData.label
                    value: modelData.value
                    link: modelData.link || ""
                    onLinkActivated: url => root.linkRequested(url)
                }
            }
        }
    }
}
