pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import "SaverModel.js" as SaverModel
import "../menubar/ClockFormat.js" as ClockFormat

// One display's screen saver (ADR-0032), the owner's four, all Grassfield drawings: the artwork drifting slowly, the
// wallpaper with a clock, a folder's pictures as a slideshow, a clock alone on black; and the moving artwork (ADR-0040 step
// 9). Display only: no field, no prompt, no window content. `active` while it is shown: the animations, the clock and the slideshow run only then. Reduce Motion: no
// drift or pan; the slideshow crossfades and the clock alone jumps without moving.
Rectangle {
    id: root

    required property var screenInfo
    property string kind: "artwork"
    property string folder: ""
    property bool active: false
    // The displays are off: the slideshow prepares nothing more (nobody sees it; the input that wakes them ends the saver).
    property bool paused: false
    // The other displays' slides, kept when this one's pruning trims the cache.
    property var keepFiles: []

    // A new slide is shown (its prepared file), for the other displays' `keepFiles`.
    signal slideShown(string file)

    // The slideshow shows the artwork until its first picture is ready, and when its folder has none.
    readonly property string effectiveKind: kind === "slideshow" && (slides.empty || slides.url === "") ? "artwork" : kind
    readonly property bool drifting: active && !Settings.reduceMotion

    color: Tokens.colorDark.shadow

    // Created with the view, so it shows the right time as soon as the saver appears (WallClock.qml).
    WallClock {
        id: clock
        enabled: root.active
    }

    // The slow pan of the artwork and of the slideshow's pictures: scaled up a little so no edge shows, out and back.
    component Drift: Item {
        id: drift

        property bool running: false
        property real phase: 0

        anchors.fill: parent
        scale: 1 + (Tokens.saverDriftScale - 1) * phase
        transformOrigin: Item.Center

        SequentialAnimation on phase {
            running: drift.running
            loops: Animation.Infinite
            NumberAnimation {
                to: 1
                duration: Tokens.saverDriftMs / 2
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                to: 0
                duration: Tokens.saverDriftMs / 2
                easing.type: Easing.InOutSine
            }
        }
    }

    // The date over the time, white, as the lock screen writes them (the saver has no account and no field). The family and
    // tracking follow the size as the clock widget's (Inter Display above typography.displayFrom: the 104-px digits set
    // tight, UI audit 2026-11-05 U24); the date in the region's order as the menu bar clock's (macOS: "Wednesday, November 5"
    // in the US, "Wednesday 5 November" in the UK).
    component ClockText: Column {
        property date date: new Date()
        property real textOpacity: 1

        readonly property bool monthFirst: ClockFormat.monthFirst(Qt.locale().dateFormat(Locale.ShortFormat))

        opacity: textOpacity

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.locale().toString(FixedTime.date(parent.date), ClockFormat.orderDate(parent.monthFirst ? qsTr("dddd, MMMM d") : qsTr("dddd d MMMM"), parent.monthFirst))
            color: Appearance.darkColors.text
            font.family: Appearance.fontFamilyFor(Tokens.saverDateSize)
            font.pixelSize: Tokens.saverDateSize
            font.weight: Tokens.saverDateWeight
            font.letterSpacing: Appearance.trackingFor(Tokens.saverDateSize)
        }

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(FixedTime.date(parent.date), SaverModel.clockFormat(Qt.locale().timeFormat(Locale.ShortFormat)))
            color: Appearance.darkColors.text
            font.family: Appearance.fontFamilyFor(Tokens.saverClockSize)
            font.pixelSize: Tokens.saverClockSize
            font.weight: Tokens.saverClockWeight
            font.letterSpacing: Appearance.trackingFor(Tokens.saverClockSize)
        }
    }

    // One of the slideshow's two pictures; `loaded` once a new picture is decoded, so it can fade in over the other.
    component Slide: Image {
        id: slide

        signal loaded

        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        opacity: 0
        onStatusChanged: if (status === Image.Ready && source !== "")
            slide.loaded()
    }

    SaverSlides {
        id: slides
        screenInfo: root.screenInfo
        folder: root.folder
        keepAlso: root.keepFiles
        running: root.active && root.kind === "slideshow" && !root.paused
        onCurrentFileChanged: if (currentFile !== "")
            root.slideShown(currentFile)
    }

    // ---- the artwork ----
    Drift {
        visible: root.effectiveKind === "artwork"
        running: root.drifting && visible

        GrassfieldArtwork {
            anchors.fill: parent
        }
    }

    // ---- the moving Grassfield artwork (ADR-0040 IQ-W3 A, step 9): its clouds drift and its light changes while the saver
    // is shown, without the pan; held still with Reduce Motion ----
    GrassfieldArtwork {
        anchors.fill: parent
        visible: root.effectiveKind === "moving"
        moving: true
        playing: root.drifting && visible
    }

    // ---- the wallpaper with a clock ----
    Item {
        id: wallpaperClock

        // The display's picture through the lock's reader (ready, and under the helper's own folders: ADR-0016), not the raw
        // published entry.
        readonly property var backdrop: SaverModel.backdrop(root.screenInfo ? {file: WallpaperState.lockStill(root.screenInfo.name)} : undefined,
            WallpaperConfig.resolve(Settings.wallpaper, {name: root.screenInfo ? root.screenInfo.name : "", model: root.screenInfo ? root.screenInfo.model : "", serial: root.screenInfo ? root.screenInfo.serialNumber : ""}))

        anchors.fill: parent
        visible: root.effectiveKind === "wallpaperClock"

        GrassfieldArtwork {
            anchors.fill: parent
            visible: wallpaperClock.backdrop.kind === "art"
        }

        Rectangle {
            anchors.fill: parent
            visible: wallpaperClock.backdrop.kind === "color"
            color: wallpaperClock.backdrop.color
        }

        // A picture the wallpaper helper prepared at this display's size (the shell decodes only those, ADR-0016).
        Image {
            anchors.fill: parent
            visible: wallpaperClock.backdrop.kind === "picture"
            source: visible ? "file://" + wallpaperClock.backdrop.file : ""
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(width * (root.screenInfo ? root.screenInfo.devicePixelRatio : 1), height * (root.screenInfo ? root.screenInfo.devicePixelRatio : 1))
            asynchronous: true
            cache: false
        }

        Rectangle {
            anchors.fill: parent
            color: Tokens.colorDark.shadow
            opacity: Tokens.saverWallpaperDimOpacity
        }

        ClockText {
            anchors.centerIn: parent
            date: clock.date
        }
    }

    // ---- the slideshow: two pictures crossfading, each panning ----
    // The new picture fades in on top while the one it replaces stays whole under it, hidden once the fade completes (as
    // Wallpaper.qml): fading both at once over the black ground dipped the light mid-dissolve (UI audit 2026-11-05 U7).
    Item {
        id: slideshow

        property int front: 0
        // The picture under the fade, hidden when it completes.
        property Item outgoing: null

        anchors.fill: parent
        visible: root.effectiveKind === "slideshow"

        Connections {
            target: slides

            function onUrlChanged(): void {
                // A fade in flight completes first: its outgoing picture is the one about to be replaced.
                if (dissolve.running)
                    dissolve.complete();
                const back = slideshow.front === 0 ? slideB : slideA;
                back.source = slides.url;
            }
        }

        function bring(slide: Item): void {
            if (dissolve.running)
                dissolve.complete();
            const other = slide === slideA ? slideB : slideA;
            front = slide === slideA ? 0 : 1;
            // Nothing on screen yet (the first picture): it fades in over the ground.
            outgoing = other.opacity > 0 ? other : null;
            other.z = 1;
            slide.z = 2;
            slide.opacity = 0;
            dissolve.target = slide;
            dissolve.start();
        }

        // The slides' crossfade is a dissolve, not motion: it is kept whole under Reduce Motion, as macOS keeps its dissolves
        // (capped at 100 ms it read as a cut; the integrator's call on #74, ADR-0039 step 6).
        NumberAnimation {
            id: dissolve

            property: "opacity"
            from: 0
            to: 1
            duration: Tokens.saverSlideFadeMs
            onFinished: {
                if (slideshow.outgoing !== null)
                    slideshow.outgoing.opacity = 0;
                slideshow.outgoing = null;
            }
        }

        Drift {
            running: root.drifting && slideshow.visible

            Slide {
                id: slideA
                onLoaded: slideshow.bring(slideA)
            }

            Slide {
                id: slideB
                onLoaded: slideshow.bring(slideB)
            }
        }
    }

    // ---- the clock alone on black, a new place every minute ----
    Item {
        anchors.fill: parent
        visible: root.effectiveKind === "clock"

        ClockText {
            id: lone

            readonly property var place: SaverModel.clockPlace(Math.floor(clock.date.getTime() / Tokens.saverClockMoveMs), root.width, root.height, width, height, Tokens.saverClockMargin)

            date: clock.date
            textOpacity: Tokens.saverClockOnlyOpacity
            x: place.x
            y: place.y
        }
    }
}
